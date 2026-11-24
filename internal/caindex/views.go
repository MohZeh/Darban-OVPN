package caindex

import (
	"fmt"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

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
	Pending      bool   // list: the pending names too
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
//	row      <rank> <name> <label> <expiry epoch, 0 unreadable> <expiry day or -> <state of the name> <last seen or ->
//	hidden   <revoked clients not listed>
//	block    <name> <why it cannot be revoked here> <serial or ->
//	pending  <name>, with Pending only: the records of the pending view, none when its CRL cannot be read
//
// One row per record with a name, in the order of index.txt; the manager sorts them. A block for each name whose
// valid certificate this menu will not revoke: ambiguous, name, missing, unreadable, mismatch or server. The files of
// the clients, a record of when each was seen and a certificate for each name, are read side by side; the records
// come out in the same order whatever the order of reading.
func List(w *records.Writer, idx *Index, o Options) {
	names := idx.Names()
	type listed struct {
		rank, cn, label, e, day, state, seen string
	}
	var rows []listed
	var seenOf []int // the rows whose client was seen, by their place in rows
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
		day := "-"
		if e > 0 {
			day = Day(e)
		}
		if label == "VALID" {
			seenOf = append(seenOf, len(rows))
		}
		rows = append(rows, listed{rank, row.CN, label, strconv.FormatInt(e, 10), day, names.Get(row.CN).State(), "-"})
	}
	each(len(seenOf), func(i int) {
		r := &rows[seenOf[i]]
		r.seen = ledgerValue(o.Ledger, r.cn, "last_seen")
	})
	for _, r := range rows {
		w.Write("row", r.rank, r.cn, r.label, r.e, r.day, r.state, r.seen)
	}
	w.Write("hidden", strconv.Itoa(hidden))

	type block struct {
		cn, why, serial string
		name            *Name
		cert            bool // the why depends on the certificate file
	}
	var blocks []block
	var certOf []int
	for _, cn := range names.Order {
		name := names.Get(cn)
		if o.isServer(name.Effective()) {
			continue
		}
		why, needCert := blockBeforeCert(cn, name)
		if why == "" && !needCert {
			continue
		}
		if needCert {
			certOf = append(certOf, len(blocks))
		}
		blocks = append(blocks, block{cn: cn, why: why, serial: "-", name: name, cert: needCert})
	}
	each(len(certOf), func(i int) {
		b := &blocks[certOf[i]]
		b.why, b.serial = blockByCert(o, b.name, ReadCert(o.PKI+"/issued/"+b.cn+".crt"))
	})
	for _, b := range blocks {
		if b.why != "" {
			w.Write("block", b.cn, b.why, b.serial)
		}
	}
	if o.Pending {
		if pending, err := pendingNames(idx, o); err == nil {
			for _, cn := range pending {
				w.Write("pending", cn)
			}
		}
	}
}

// blockReason is revoke_block_reason of lib/darban/clients.sh, as a code the manager turns into its text.
func blockReason(o Options, cn string, name *Name) (string, string) {
	why, needCert := blockBeforeCert(cn, name)
	if !needCert {
		if why == "" {
			return "", ""
		}
		return why, "-"
	}
	return blockByCert(o, name, ReadCert(o.PKI+"/issued/"+cn+".crt"))
}

// blockBeforeCert is the part of blockReason that needs no file: a reason, or whether the certificate decides.
func blockBeforeCert(cn string, name *Name) (string, bool) {
	switch name.State() {
	case "AMBIGUOUS":
		return "ambiguous", false
	case "V":
	default:
		return "", false
	}
	if !validName.MatchString(cn) || cn == "server" {
		return "name", false
	}
	return "", true
}

// blockByCert is the rest of blockReason: what the certificate file of a name with one valid record says.
func blockByCert(o Options, name *Name, cert Cert) (string, string) {
	serial := name.LastV.Serial
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

// each calls f(0) to f(n-1), side by side on the processors there are. Each call may change only what belongs to
// its own number.
func each(n int, f func(int)) {
	workers := runtime.GOMAXPROCS(0)
	if workers > n {
		workers = n
	}
	if workers <= 1 {
		for i := 0; i < n; i++ {
			f(i)
		}
		return
	}
	var next atomic.Int64
	var wg sync.WaitGroup
	for k := 0; k < workers; k++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				f(i)
			}
		}()
	}
	wg.Wait()
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

// Serials writes "serial <place> <state>" for each given serial that the database has, by its place among the given
// ones, counted from 1: the state of the first record with that serial (index_state_of_serial in
// lib/darban/clients.sh). A serial that is not hex, or that the database does not have, gets no record. One call
// answers for every profile kept on the server, so the menu reads the database once, not once for each of them.
func Serials(w *records.Writer, idx *Index, serials []string) {
	state := make(map[string]string, len(idx.Rows))
	for _, row := range idx.Rows {
		if _, seen := state[row.Norm]; !seen {
			state[row.Norm] = row.State
		}
	}
	for i, serial := range serials {
		norm, err := NormSerial(serial)
		if err != nil {
			continue
		}
		if s, known := state[norm]; known {
			w.Write("serial", strconv.Itoa(i+1), s)
		}
	}
}

// Pending writes "pending <name>" for each revoked client the CRL does not list yet and whose certificate has
// not expired: revoked in the CA, not yet blocked by OpenVPN (revocation_pending_names in lib/darban/clients.sh).
// Without a CRL, every such client is pending.
func Pending(w *records.Writer, idx *Index, o Options) error {
	pending, err := pendingNames(idx, o)
	if err != nil {
		return err
	}
	for _, cn := range pending {
		w.Write("pending", cn)
	}
	return nil
}

// pendingNames are the names Pending writes, in the order of index.txt.
func pendingNames(idx *Index, o Options) ([]string, error) {
	listed := map[string]bool{}
	if o.CRL != "" {
		serials, err := CRLSerials(o.CRL)
		if err != nil {
			return nil, err
		}
		for _, serial := range serials {
			listed[serial] = true
		}
	}
	var pending []string
	for _, row := range idx.Rows {
		if !row.HasCN || row.CN == "" || row.State != "R" || listed[row.Norm] {
			continue
		}
		e, ok := ExpiryEpoch(row.Expiry)
		// An unreadable date counts as not expired.
		if !ok || e > o.Now {
			pending = append(pending, row.CN)
		}
	}
	return pending, nil
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
