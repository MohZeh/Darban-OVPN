package caindex

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/MohZeh/Darban-OVPN/internal/records"
)

// now is the time every test judges expiry by: 2026-11-23 00:00:00 UTC.
const now = int64(1795392000)

type pki struct {
	t    *testing.T
	dir  string
	key  *ecdsa.PrivateKey
	ca   *x509.Certificate
	rows []string
}

func newPKI(t *testing.T) *pki {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "issued"), 0o700); err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "TestCA"},
		NotBefore: time.Unix(now-86400, 0), NotAfter: time.Unix(now+3650*86400, 0),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return &pki{t: t, dir: dir, key: key, ca: ca}
}

// issue writes issued/<name>.crt, signed by the CA, with that serial and extended key usage.
func (p *pki) issue(name string, serial int64, usage x509.ExtKeyUsage) {
	p.t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		p.t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: name},
		NotBefore: time.Unix(now-86400, 0), NotAfter: time.Unix(now+825*86400, 0),
		ExtKeyUsage: []x509.ExtKeyUsage{usage},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, p.ca, &key.PublicKey, p.key)
	if err != nil {
		p.t.Fatal(err)
	}
	p.write("issued/"+name+".crt", string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})))
}

// crl writes crl.pem, revoking these serials.
func (p *pki) crl(serials ...int64) string {
	p.t.Helper()
	var entries []x509.RevocationListEntry
	for _, serial := range serials {
		entries = append(entries, x509.RevocationListEntry{SerialNumber: big.NewInt(serial), RevocationTime: time.Unix(now-3600, 0)})
	}
	der, err := x509.CreateRevocationList(rand.Reader, &x509.RevocationList{
		Number: big.NewInt(1000), ThisUpdate: time.Unix(now-60, 0), NextUpdate: time.Unix(now+180*86400, 0),
		RevokedCertificateEntries: entries,
	}, p.ca, p.key)
	if err != nil {
		p.t.Fatal(err)
	}
	p.write("crl.pem", string(pem.EncodeToMemory(&pem.Block{Type: "X509 CRL", Bytes: der})))
	return filepath.Join(p.dir, "crl.pem")
}

func (p *pki) row(state, expiry, serial, subject string) {
	revoked := ""
	if state == "R" {
		revoked = "261101000000Z"
	}
	p.rows = append(p.rows, strings.Join([]string{state, expiry, revoked, serial, "unknown", subject}, "\t"))
}

func (p *pki) write(name, text string) {
	p.t.Helper()
	if err := os.WriteFile(filepath.Join(p.dir, name), []byte(text), 0o600); err != nil {
		p.t.Fatal(err)
	}
}

func (p *pki) index() *Index {
	p.t.Helper()
	p.write("index.txt", strings.Join(p.rows, "\n")+"\n")
	idx, err := Read(p.dir)
	if err != nil {
		p.t.Fatal(err)
	}
	return idx
}

func output(t *testing.T, view func(*records.Writer)) string {
	t.Helper()
	var out bytes.Buffer
	w := records.NewWriter(&out)
	view(w)
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestNormSerial(t *testing.T) {
	for in, want := range map[string]string{"0a:1B": "A1B", "000": "0", "00ff": "FF", "C0000000000000000000000000000001": "C0000000000000000000000000000001"} {
		if got, err := NormSerial(in); err != nil || got != want {
			t.Errorf("NormSerial(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "xyz", "-1"} {
		if _, err := NormSerial(in); err == nil {
			t.Errorf("NormSerial(%q) accepted", in)
		}
	}
}

func TestExpiryEpoch(t *testing.T) {
	cases := map[string]int64{
		"491231235959Z":   2524607999, // UTCTime before 50: the 2000s
		"500101000000Z":   -631152000, // from 50: the 1900s
		"20291231235959Z": 1893455999,
		"261123000000Z":   now,
	}
	for in, want := range cases {
		if got, ok := ExpiryEpoch(in); !ok || got != want {
			t.Errorf("ExpiryEpoch(%q) = %d, %v; want %d", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "260230000000Z", "261301000000Z", "261123240000Z", "261123000060Z", "2611230000Z", "26112300000aZ", "261123000000"} {
		if _, ok := ExpiryEpoch(in); ok {
			t.Errorf("ExpiryEpoch(%q) accepted a date that does not exist", in)
		}
	}
	if got := Day(1893455999); got != "2029-12-31" {
		t.Errorf("Day = %q", got)
	}
}

func TestMalformedOrUnreadableIndexIsAnErrorNeverAnEmptyList(t *testing.T) {
	dir := t.TempDir()
	_, err := Read(dir)
	if err == nil || err.Error() != "CA database is missing or unreadable: "+dir+"/index.txt" {
		t.Fatalf("missing index: %v", err)
	}
	if err := os.Mkdir(filepath.Join(dir, "index.txt"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(dir); err == nil || !strings.HasPrefix(err.Error(), "Could not read the CA database: ") {
		t.Fatalf("a folder as index: %v", err)
	}
	good := "V\t291231235959Z\t\t0A\tunknown\t/CN=alice"
	for name, text := range map[string]string{
		"garbage line":   good + "\ngarbage line\n",
		"five fields":    "V\t291231235959Z\t\t0A\tunknown\n",
		"bad state":      "X\t291231235959Z\t\t0A\tunknown\t/CN=a\n",
		"no expiry":      "V\t\t\t0A\tunknown\t/CN=a\n",
		"serial not hex": "V\t291231235959Z\t\t0G\tunknown\t/CN=a\n",
		"empty line":     good + "\n\n" + good + "\n",
		"NUL":            good + "\x00\n",
	} {
		if _, err := Parse("/pki/index.txt", []byte(text)); err == nil || err.Error() != "CA database has a malformed record: /pki/index.txt" {
			t.Errorf("%s: %v", name, err)
		}
	}
	idx, err := Parse("/pki/index.txt", nil)
	if err != nil || len(idx.Rows) != 0 {
		t.Fatalf("an empty index is a valid one with no rows: %v", err)
	}
	idx, err = Parse("/pki/index.txt", []byte(good))
	if err != nil || len(idx.Rows) != 1 {
		t.Fatalf("a last line without its line break: %v", err)
	}
}

func TestCommonNames(t *testing.T) {
	idx, err := Parse("i", []byte(strings.Join([]string{
		"V\t291231235959Z\t\t01\tunknown\t/C=IR/CN=first/O=x/CN=second/OU=y",
		"V\t291231235959Z\t\t02\tunknown\t/O=no-name",
		"V\t291231235959Z\t\t03\tunknown\t/CN=",
	}, "\n")))
	if err != nil {
		t.Fatal(err)
	}
	if r := idx.Rows[0]; !r.HasCN || r.CN != "second" {
		t.Errorf("the last CN, up to the next slash: %+v", r)
	}
	if idx.Rows[1].HasCN || !idx.Rows[2].HasCN || idx.Rows[2].CN != "" {
		t.Errorf("rows without a name: %+v", idx.Rows[1:])
	}
	if names := idx.Names(); len(names.Order) != 1 {
		t.Errorf("an empty name is never listed: %v", names.Order)
	}
}

func TestList(t *testing.T) {
	p := newPKI(t)
	p.issue("server", 0x10, x509.ExtKeyUsageServerAuth)
	p.issue("alice", 0x11, x509.ExtKeyUsageClientAuth)
	p.issue("bob", 0x13, x509.ExtKeyUsageClientAuth)
	p.issue("srv2", 0x14, x509.ExtKeyUsageServerAuth)
	p.issue("swap", 0x99, x509.ExtKeyUsageClientAuth)
	p.write("issued/junk.crt", "not a certificate\n")
	p.row("V", "291231235959Z", "10", "/CN=server")
	p.row("V", "291231235959Z", "11", "/CN=alice")
	p.row("R", "291231235959Z", "12", "/CN=bob")
	p.row("V", "291231235959Z", "13", "/CN=bob")
	p.row("V", "291231235959Z", "14", "/CN=srv2")
	p.row("V", "291231235959Z", "15", "/CN=swap")
	p.row("V", "291231235959Z", "16", "/CN=junk")
	p.row("V", "291231235959Z", "17", "/CN=gone")
	p.row("V", "201231235959Z", "18", "/CN=old")
	p.row("E", "201231235959Z", "19", "/CN=older")
	p.row("V", "bad", "1A", "/CN=baddate")
	p.row("V", "291231235959Z", "1B", "/CN=twin")
	p.row("V", "291231235959Z", "1C", "/CN=twin")
	p.row("V", "291231235959Z", "1D", "/CN=bad name")
	p.row("R", "291231235959Z", "1E", "/CN=carol")
	idx := p.index()
	ledger := t.TempDir()
	if err := os.WriteFile(filepath.Join(ledger, "alice"), []byte("first_seen=1700000000000000\nlast_seen=junk\nlast_seen=1795391000000000\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	o := Options{PKI: p.dir, Now: now, ServerSerial: "10", Ledger: ledger}
	e := "1893455999"
	want := strings.Join([]string{
		"row\t1\talice\tVALID\t" + e + "\t2029-12-31\tV\t1795391000000000",
		"row\t1\tbob\tVALID\t" + e + "\t2029-12-31\tV\t-",
		"row\t1\tsrv2\tVALID\t" + e + "\t2029-12-31\tV\t-",
		"row\t1\tswap\tVALID\t" + e + "\t2029-12-31\tV\t-",
		"row\t1\tjunk\tVALID\t" + e + "\t2029-12-31\tV\t-",
		"row\t1\tgone\tVALID\t" + e + "\t2029-12-31\tV\t-",
		"row\t2\told\tEXPIRED\t1609459199\t2020-12-31\tV\t-",
		"row\t2\tolder\tEXPIRED\t1609459199\t2020-12-31\tE\t-",
		"row\t2\tbaddate\tBAD-DATE\t0\t-\tV\t-",
		"row\t1\ttwin\tVALID\t" + e + "\t2029-12-31\tAMBIGUOUS\t-",
		"row\t1\ttwin\tVALID\t" + e + "\t2029-12-31\tAMBIGUOUS\t-",
		"row\t1\tbad name\tVALID\t" + e + "\t2029-12-31\tV\t-",
		"hidden\t2",
		"block\tsrv2\tserver\t14",
		"block\tswap\tmismatch\t15",
		"block\tjunk\tunreadable\t16",
		"block\tgone\tmissing\t17",
		"block\told\tmissing\t18",
		"block\tbaddate\tmissing\t1A",
		"block\ttwin\tambiguous\t-",
		"block\tbad name\tname\t-",
	}, "\n") + "\n"
	if got := output(t, func(w *records.Writer) { List(w, idx, o) }); got != want {
		t.Errorf("list:\n%s\nwant:\n%s", got, want)
	}
	o.All = true
	got := output(t, func(w *records.Writer) { List(w, idx, o) })
	for _, line := range []string{"row\t3\tbob\tREVOKED\t" + e + "\t2029-12-31\tV\t-", "row\t3\tcarol\tREVOKED\t" + e + "\t2029-12-31\tR\t-", "hidden\t0"} {
		if !strings.Contains(got, line+"\n") {
			t.Errorf("--all lacks %q:\n%s", line, got)
		}
	}
}

func TestStats(t *testing.T) {
	p := newPKI(t)
	p.row("V", "291231235959Z", "10", "/CN=server")
	p.row("V", "291231235959Z", "11", "/CN=a")
	p.row("V", "261201000000Z", "12", "/CN=soon")
	p.row("V", "201231235959Z", "13", "/CN=old")
	p.row("R", "291231235959Z", "14", "/CN=gone")
	p.row("V", "bad", "15", "/CN=bad")
	got := output(t, func(w *records.Writer) { Stats(w, p.index(), Options{Now: now, ServerSerial: "10", WarnDays: 30}) })
	if got != "stats\t2\t1\t2\t1\n" {
		t.Errorf("stats = %q", got)
	}
}

func TestPending(t *testing.T) {
	p := newPKI(t)
	p.row("V", "291231235959Z", "10", "/CN=server")
	p.row("R", "291231235959Z", "11", "/CN=listed")
	p.row("R", "291231235959Z", "12", "/CN=waiting")
	p.row("R", "201231235959Z", "13", "/CN=expired")
	p.row("R", "bad", "14", "/CN=unreadable-date")
	idx := p.index()
	crl := p.crl(0x11)
	got := output(t, func(w *records.Writer) {
		if err := Pending(w, idx, Options{Now: now, CRL: crl}); err != nil {
			t.Fatal(err)
		}
	})
	if got != "pending\twaiting\npending\tunreadable-date\n" {
		t.Errorf("pending = %q", got)
	}
	got = output(t, func(w *records.Writer) {
		if err := Pending(w, idx, Options{Now: now}); err != nil {
			t.Fatal(err)
		}
	})
	if got != "pending\tlisted\npending\twaiting\npending\tunreadable-date\n" {
		t.Errorf("without a CRL, every unexpired revoked client is pending: %q", got)
	}
	p.write("crl.pem", "not a CRL\n")
	var out bytes.Buffer
	if err := Pending(records.NewWriter(&out), idx, Options{Now: now, CRL: crl}); err == nil {
		t.Error("a CRL that cannot be read was taken as empty")
	}
}

func TestCheckCRL(t *testing.T) {
	p := newPKI(t)
	p.row("V", "291231235959Z", "10", "/CN=server")
	p.row("R", "291231235959Z", "11", "/CN=revoked")
	p.row("R", "201231235959Z", "12", "/CN=expired")
	idx := p.index()
	o := Options{PKI: p.dir, Now: now, ServerSerial: "10"}
	check := func(want string, serials ...int64) {
		t.Helper()
		o.CRL = p.crl(serials...)
		err := CheckCRL(idx, o)
		if want == "" && err != nil || want != "" && (err == nil || err.Error() != want) {
			t.Errorf("CRL %v: got %v, want %q", serials, err, want)
		}
	}
	check("", 0x11)
	check("", 0x11, 0x12)
	check("CRL is missing revoked CA serial: 11")
	check("CRL revokes serial(s) the CA database does not: 10 AB. "+rollbackHint(p.dir+"/index.txt"), 0x11, 0x10, 0xAB)
	o.ServerSerial = "99"
	check("CA database does not contain the server certificate (serial 99): it is empty, restored from an old backup, or from another CA.", 0x11)
	o.ServerSerial = ""
	check("Cannot read the server certificate from server.conf.", 0x11)
	o.ServerSerial = "10"
	p.write("crl.pem", "not a CRL\n")
	if err := CheckCRL(idx, o); err == nil || err.Error() != "Could not read the serials of the CRL." {
		t.Errorf("an unreadable CRL: %v", err)
	}
	p.rows = append(p.rows[:1], "R\tbad\t261101000000Z\t11\tunknown\t/CN=revoked")
	idx = p.index()
	o.CRL = p.crl(0x11)
	var problem *Error
	if err := CheckCRL(idx, o); !errors.As(err, &problem) || err.Error() != "Malformed expiry for revoked CA serial: 11" {
		t.Errorf("a revoked row without a date: %v", err)
	}
}

func TestReadCert(t *testing.T) {
	p := newPKI(t)
	p.issue("a", 0x0ABC, x509.ExtKeyUsageClientAuth)
	c := ReadCert(filepath.Join(p.dir, "issued", "a.crt"))
	if !c.Present || !c.Readable || c.Norm != "ABC" || c.ServerAuth {
		t.Errorf("a client certificate: %+v", c)
	}
	p.write("issued/empty.crt", "")
	if c := ReadCert(filepath.Join(p.dir, "issued", "empty.crt")); c.Present {
		t.Errorf("an empty file is missing: %+v", c)
	}
	if c := ReadCert(filepath.Join(p.dir, "issued", "none.crt")); c.Present {
		t.Errorf("no file: %+v", c)
	}
	p.write("issued/text.crt", fmt.Sprintf("Certificate:\n    text before it\n%s", mustRead(t, filepath.Join(p.dir, "issued", "a.crt"))))
	if c := ReadCert(filepath.Join(p.dir, "issued", "text.crt")); !c.Readable || c.Norm != "ABC" {
		t.Errorf("text before the PEM block, as openssl -text leaves it: %+v", c)
	}
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
