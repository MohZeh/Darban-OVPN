// Command darban-core is the part of Darban OVPN written in Go. The manager in Bash runs it; it reads its options
// from the command line only, never from the environment, and writes records for Bash on standard output
// (internal/records). Errors go to standard error as "ERROR: ...", with exit status 1; a usage error exits with 2.
//
//	darban-core version
//	darban-core index --pki DIR --view list|stats|pending|crl [options]
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/MohZeh/Darban-OVPN/internal/buildinfo"
	"github.com/MohZeh/Darban-OVPN/internal/caindex"
	"github.com/MohZeh/Darban-OVPN/internal/records"
)

const usage = `Usage:
  darban-core version
  darban-core index --pki DIR --view VIEW [options]

Views of the CA database (index.txt), its certificates and the CRL, as records for the manager:
  list     the rows of "darban list", and why a valid certificate cannot be revoked here
  stats    the number of valid, revoked, expired and soon expiring clients
  pending  revoked clients the CRL does not list yet
  crl      whether the CRL and the database agree (exit 1 and the reason when not)

Options:
  --now EPOCH            the time to judge expiry by; default: now
  --server-serial HEX    the certificate OpenVPN serves, which is never listed
  --all                  list: the revoked clients too
  --ledger DIR           list: the records of when each client was seen
  --warn-days N          stats: a client expiring within N days counts as soon (default 30)
  --crl FILE             pending, crl: a CRL whose signature was verified
`

// errUsage is a mistake in the command line.
var errUsage = errors.New("usage")

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	var err error
	switch args[0] {
	case "version", "--version":
		if len(args) != 1 {
			err = errUsage
			break
		}
		fmt.Fprintln(stdout, buildinfo.Version)
		return 0
	case "index":
		err = index(args[1:], stdout)
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usage)
		return 0
	default:
		err = errUsage
	}
	if errors.Is(err, errUsage) {
		fmt.Fprint(stderr, usage)
		return 2
	}
	if errors.Is(err, errSilent) {
		return 1
	}
	if err != nil {
		fmt.Fprintf(stderr, "ERROR: %s\n", err)
		return 1
	}
	return 0
}

func index(args []string, stdout io.Writer) error {
	flags := flag.NewFlagSet("index", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var o caindex.Options
	var view, now string
	flags.StringVar(&o.PKI, "pki", "", "")
	flags.StringVar(&view, "view", "", "")
	flags.StringVar(&now, "now", "", "")
	flags.StringVar(&o.ServerSerial, "server-serial", "", "")
	flags.BoolVar(&o.All, "all", false, "")
	flags.StringVar(&o.Ledger, "ledger", "", "")
	flags.Int64Var(&o.WarnDays, "warn-days", 30, "")
	flags.StringVar(&o.CRL, "crl", "", "")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || o.PKI == "" || o.WarnDays < 0 {
		return errUsage
	}
	o.Now = time.Now().Unix()
	if now != "" {
		value, err := strconv.ParseInt(now, 10, 64)
		if err != nil {
			return errUsage
		}
		o.Now = value
	}
	if view == "crl" && o.CRL == "" {
		return errUsage
	}
	idx, err := caindex.Read(o.PKI)
	if err != nil {
		return err
	}
	w := records.NewWriter(stdout)
	switch view {
	case "list":
		caindex.List(w, idx, o)
	case "stats":
		caindex.Stats(w, idx, o)
	case "pending":
		// As before, a CRL that cannot be read is said by the exit status alone: every caller has its own words.
		if err := caindex.Pending(w, idx, o); err != nil {
			return errSilent
		}
	case "crl":
		return caindex.CheckCRL(idx, o)
	default:
		return errUsage
	}
	return w.Flush()
}

// errSilent fails without a message.
var errSilent = silentError{}

type silentError struct{}

func (silentError) Error() string { return "" }
