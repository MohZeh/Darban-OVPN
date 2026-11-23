// Package caindex reads the CA database of Easy-RSA (OpenSSL's index.txt), the client certificates and the CRL,
// once each, for the screens of the manager that list them. It reads only; nothing here writes a file.
//
// Each rule here is the one the Bash code used before, so the screens read the same: lib/common.sh
// (darban_index_rows, darban_norm_serial, darban_index_expiry_epoch, darban_verify_crl) and lib/darban/clients.sh
// (client_index_rows, client_index_lookup, client_effective_rows, revoke_block_reason). Unlike client_index_rows,
// a database that cannot be read, or that holds a malformed record, is an error and never an empty list (H6).
package caindex

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// MaxIndexSize is the largest index.txt read: about a million rows.
const MaxIndexSize = 256 << 20

// Row is one record of index.txt.
type Row struct {
	Line    int
	State   string // V, R, E or S
	Expiry  string // ASN.1 UTCTime or GeneralizedTime, as written
	Serial  string // hex, as written
	Norm    string // the serial in the form NormSerial gives
	Subject string
	// CN is the common name of the subject, when it has one (HasCN). Empty names are never listed.
	CN    string
	HasCN bool
}

// Index is the CA database of one PKI.
type Index struct {
	Path string
	Rows []Row
}

// Error is a problem with the CA database, worded as the manager words it.
type Error struct{ Message string }

func (e *Error) Error() string { return e.Message }

func indexError(format string, args ...any) error {
	return &Error{Message: fmt.Sprintf(format, args...)}
}

// IndexPath is where a PKI keeps its database, written as the manager writes "$DARBAN_PKI/index.txt".
func IndexPath(pki string) string { return pki + "/index.txt" }

// Read reads and checks every record of pki/index.txt.
func Read(pki string) (*Index, error) {
	path := IndexPath(pki)
	file, err := os.Open(path)
	if err != nil {
		return nil, indexError("CA database is missing or unreadable: %s", path)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, MaxIndexSize+1))
	if err != nil || len(data) > MaxIndexSize {
		return nil, indexError("Could not read the CA database: %s", path)
	}
	return Parse(path, data)
}

// Parse checks the records of a database read from path. A record is malformed when it has fewer than six
// fields, a state other than V, R, E or S, no expiry, or a serial that is not hex; an empty line is one too.
func Parse(path string, data []byte) (*Index, error) {
	idx := &Index{Path: path}
	if len(data) == 0 {
		return idx, nil
	}
	if bytes.IndexByte(data, 0) >= 0 {
		return nil, indexError("CA database has a malformed record: %s", path)
	}
	text := strings.TrimSuffix(string(data), "\n")
	for number, line := range strings.Split(text, "\n") {
		fields := strings.Split(line, "\t")
		if line == "" || len(fields) < 6 || !validState(fields[0]) || fields[1] == "" || !isHex(fields[3]) {
			return nil, indexError("CA database has a malformed record: %s", path)
		}
		norm, _ := NormSerial(fields[3])
		row := Row{Line: number + 1, State: fields[0], Expiry: fields[1], Serial: fields[3], Norm: norm, Subject: fields[5]}
		if at := strings.LastIndex(row.Subject, "/CN="); at >= 0 {
			row.HasCN = true
			row.CN = row.Subject[at+len("/CN="):]
			if slash := strings.IndexByte(row.CN, '/'); slash >= 0 {
				row.CN = row.CN[:slash]
			}
		}
		idx.Rows = append(idx.Rows, row)
	}
	return idx, nil
}

func validState(s string) bool { return s == "V" || s == "R" || s == "E" || s == "S" }

func isHex(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

// ErrSerial is a serial that is not hex.
var ErrSerial = errors.New("malformed serial")

// NormSerial is a serial in upper case, without colons or leading zeros, as darban_norm_serial gives it.
func NormSerial(serial string) (string, error) {
	s := strings.ToUpper(strings.ReplaceAll(serial, ":", ""))
	for len(s) > 1 && s[0] == '0' {
		s = s[1:]
	}
	if !isHex(s) {
		return "", ErrSerial
	}
	return s, nil
}

// Names is what the CA says of each common name, in the order of its first record.
type Names struct {
	Order []string
	byCN  map[string]*Name
}

// Name sums up the records of one common name.
type Name struct {
	Records int
	Valid   int
	Last    Row // the newest record
	LastV   Row // the newest valid record, when Valid > 0
}

// State is the state the manager gives a name: AMBIGUOUS for more than one valid record, V for one, otherwise
// the state of its newest record.
func (n *Name) State() string {
	switch {
	case n.Valid > 1:
		return "AMBIGUOUS"
	case n.Valid == 1:
		return "V"
	}
	return n.Last.State
}

// Effective is the record a name stands for: its valid one, otherwise its newest.
func (n *Name) Effective() Row {
	if n.Valid > 0 {
		return n.LastV
	}
	return n.Last
}

// Names sums up the records that have a common name. A record whose common name is empty is left out.
func (idx *Index) Names() *Names {
	names := &Names{byCN: map[string]*Name{}}
	for _, row := range idx.Rows {
		if !row.HasCN || row.CN == "" {
			continue
		}
		name, known := names.byCN[row.CN]
		if !known {
			name = &Name{}
			names.byCN[row.CN] = name
			names.Order = append(names.Order, row.CN)
		}
		name.Records++
		name.Last = row
		if row.State == "V" {
			name.Valid++
			name.LastV = row
		}
	}
	return names
}

// Get returns what the CA says of one name, or nil.
func (n *Names) Get(cn string) *Name { return n.byCN[cn] }
