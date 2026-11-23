package caindex

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/MohZeh/Darban-OVPN/internal/records"
)

// Options are what the manager knows and the CA does not.
type Options struct {
	PKI          string
	Now          int64
	ServerSerial string // the certificate OpenVPN serves, never listed; empty when unknown
	All          bool   // list the revoked clients too
	Ledger       string // the folder of the records of when each client was seen
	WarnDays     int64
	CRL          string // a CRL whose signature the caller has verified
}

func (o Options) isServer(row Row) bool {
	if o.ServerSerial == "" {
		return false
	}
	want, err := NormSerial(o.ServerSerial)
	return err == nil && row.Norm == want
}

// validName is valid_existing_name of lib/darban/core.sh: a name this tool can manage.
var validName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$`)

// List writes the records of "darban list" (list_clients in lib/darban/clients.sh):
//
//	row     <rank> <name> <label> <expiry epoch, 0 unreadable> <expiry day or -> <state of the name> <last seen or ->
//	hidden  <revoked clients not listed>
//	block   <name> <why it cannot be revoked here> <serial or ->
//
// One row per record with a name, in the order of index.txt; the manager sorts them. A block for each name whose
// valid certificate this menu will not revoke: ambiguous, name, missing, unreadable, mismatch or server.
func List(w *records.Writer, idx *Index, o Options) {
	names := idx.Names()
	hidden := 0
	for _, row := range idx.Rows {
		if !row.HasCN || row.CN == "" || o.isServer(row) {
			continue
		}
		if row.State == "R" && !o.All {
			hidden++
			continue
		}
		e, ok := ExpiryEpoch(row.Expiry)
		if !ok {
			e = 0
		}
		var label, rank string
		switch row.State {
		case "V":
			if e > o.Now {
				label, rank = "VALID", "1"
			} else {
				label, rank = "EXPIRED", "2"
			}
		case "R":
			label, rank = "REVOKED", "3"
		case "E":
			label, rank = "EXPIRED", "2"
		default:
			label, rank = row.State, "4"
		}
		if e == 0 {
			label = "BAD-DATE"
		}
		day, seen := "-", "-"
		if e > 0 {
			day = Day(e)
		}
		if label == "VALID" {
			seen = ledgerValue(o.Ledger, row.CN, "last_seen")
		}
		w.Write("row", rank, row.CN, label, strconv.FormatInt(e, 10), day, names.Get(row.CN).State(), seen)
	}
	w.Write("hidden", strconv.Itoa(hidden))
	for _, cn := range names.Order {
		name := names.Get(cn)
		if o.isServer(name.Effective()) {
			continue
		}
		if why, serial := blockReason(o, cn, name); why != "" {
			w.Write("block", cn, why, serial)
		}
	}
}

// blockReason is revoke_block_reason of lib/darban/clients.sh, as a code the manager turns into its text.
func blockReason(o Options, cn string, name *Name) (string, string) {
	switch name.State() {
	case "AMBIGUOUS":
		return "ambiguous", "-"
	case "V":
	default:
		return "", ""
	}
	if !validName.MatchString(cn) || cn == "server" {
		return "name", "-"
	}
	serial := name.LastV.Serial
	cert := ReadCert(o.PKI + "/issued/" + cn + ".crt")
	switch {
	case !cert.Present:
		return "missing", serial
	case !cert.Readable:
		return "unreadable", serial
	case cert.Norm != name.LastV.Norm:
		return "mismatch", serial
	case cert.ServerAuth || o.isServer(Row{Norm: cert.Norm}):
		return "server", serial
	}
	return "", ""
}

// ledgerValue is ledger_value of lib/darban/events.sh: the last value of one key in a client's record, or "-".
func ledgerValue(dir, cn, key string) string {
	if dir == "" || strings.Contains(cn, "/") || cn == "." || cn == ".." {
		return "-"
	}
	path := dir + "/" + cn
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return "-"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "-"
	}
	value := "-"
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Split(line, "=")
		if len(fields) >= 2 && fields[0] == key && ledgerText.MatchString(fields[1]) {
			value = fields[1]
		}
	}
	return value
}

var ledgerText = regexp.MustCompile(`^[0-9A-Fa-f.:]+$`)

// Stats writes "stats <valid> <revoked> <expired> <expiring soon>" (client_stats in lib/darban/clients.sh).
func Stats(w *records.Writer, idx *Index, o Options) {
	var valid, revoked, expired, soon int
	for _, row := range idx.Rows {
		if !row.HasCN || row.CN == "" || o.isServer(row) {
			continue
		}
		e, ok := ExpiryEpoch(row.Expiry)
		if !ok {
			e = 0
		}
		switch {
		case row.State == "R":
			revoked++
		case row.State == "V" && e > o.Now:
			valid++
			if e-o.Now <= o.WarnDays*86400 {
				soon++
			}
		default:
			expired++
		}
	}
	w.Write("stats", strconv.Itoa(valid), strconv.Itoa(revoked), strconv.Itoa(expired), strconv.Itoa(soon))
}

// Pending writes "pending <name>" for each revoked client the CRL does not list yet and whose certificate has
// not expired: revoked in the CA, not yet blocked by OpenVPN (revocation_pending_names in lib/darban/clients.sh).
// Without a CRL, every such client is pending.
func Pending(w *records.Writer, idx *Index, o Options) error {
	listed := map[string]bool{}
	if o.CRL != "" {
		serials, err := CRLSerials(o.CRL)
		if err != nil {
			return err
		}
		for _, serial := range serials {
			listed[serial] = true
		}
	}
	for _, row := range idx.Rows {
		if !row.HasCN || row.CN == "" || row.State != "R" || listed[row.Norm] {
			continue
		}
		e, ok := ExpiryEpoch(row.Expiry)
		// An unreadable date counts as not expired.
		if !ok || e > o.Now {
			w.Write("pending", row.CN)
		}
	}
	return nil
}

// CheckCRL compares the CRL with the database, as the second half of darban_verify_crl in lib/common.sh: the
// caller checked the file, its signature and its dates. It returns the first problem, worded as there.
func CheckCRL(idx *Index, o Options) error {
	if o.ServerSerial == "" {
		return indexError("Cannot read the server certificate from server.conf.")
	}
	server, err := NormSerial(o.ServerSerial)
	if err != nil {
		return indexError("Cannot read the server certificate from server.conf.")
	}
	state, expiry := map[string]string{}, map[string]string{}
	for _, row := range idx.Rows {
		state[row.Norm] = row.State
		expiry[row.Norm] = row.Expiry
	}
	if _, known := state[server]; !known {
		return indexError("CA database does not contain the server certificate (serial %s): it is empty, restored from an old backup, or from another CA.", server)
	}
	serials, err := CRLSerials(o.CRL)
	if err == ErrCRLSerial {
		return indexError("Malformed serial in CRL.")
	}
	if err != nil {
		return indexError("Could not read the serials of the CRL.")
	}
	included := map[string]bool{}
	for _, serial := range serials {
		included[serial] = true
	}
	// An expired revoked certificate cannot authenticate and may leave the CRL. Every other must be there.
	for _, row := range idx.Rows {
		if row.State != "R" {
			continue
		}
		e, ok := ExpiryEpoch(row.Expiry)
		if !ok {
			return indexError("Malformed expiry for revoked CA serial: %s", row.Norm)
		}
		if e > o.Now && !included[row.Norm] {
			return indexError("CRL is missing revoked CA serial: %s", row.Norm)
		}
	}
	// The other way: the CRL revokes what the database does not, unless that certificate has expired.
	var unknown []string
	for _, serial := range serials {
		if state[serial] == "R" {
			continue
		}
		if written, known := expiry[serial]; known {
			if e, ok := ExpiryEpoch(written); ok && e <= o.Now {
				continue
			}
		}
		unknown = append(unknown, serial)
	}
	if len(unknown) > 0 {
		return indexError("CRL revokes serial(s) the CA database does not: %s. %s", strings.Join(unknown, " "), rollbackHint(idx.Path))
	}
	return nil
}

// rollbackHint is darban_rollback_hint of lib/common.sh.
func rollbackHint(index string) string {
	return fmt.Sprintf("The CA database looks older than the published CRL (restored backup?). Restore the current %s. Only if un-revoking is really intended: darban-crl-maintain --renew --allow-crl-shrink", index)
}
