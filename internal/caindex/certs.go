package caindex

import (
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"strings"
)

// MaxPEMSize is the largest certificate or CRL file read.
const MaxPEMSize = 64 << 20

var errNoPEM = errors.New("no PEM block of that type")

// readPEM returns the first PEM block of one of the given types in a file, as openssl -in reads a PEM file.
func readPEM(path string, types ...string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > MaxPEMSize {
		return nil, fmt.Errorf("%s: not a regular file of at most %d bytes", path, MaxPEMSize)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	for {
		var block *pem.Block
		block, data = pem.Decode(data)
		if block == nil {
			return nil, errNoPEM
		}
		for _, kind := range types {
			if block.Type == kind {
				return block.Bytes, nil
			}
		}
	}
}

// Cert is what the list needs of a client certificate file.
type Cert struct {
	Present    bool   // the file exists and is not empty
	Readable   bool   // it holds a certificate
	Norm       string // its serial, as NormSerial gives it
	ServerAuth bool   // its extended key usage allows a TLS server
}

// ReadCert reads one certificate file. A file that is missing or empty is not Present; one that holds no
// certificate is not Readable.
func ReadCert(path string) Cert {
	info, err := os.Stat(path)
	if err != nil || info.Size() == 0 {
		return Cert{}
	}
	c := Cert{Present: true}
	der, err := readPEM(path, "CERTIFICATE", "X509 CERTIFICATE", "TRUSTED CERTIFICATE")
	if err != nil {
		return c
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil || cert.SerialNumber == nil || cert.SerialNumber.Sign() < 0 {
		return c
	}
	c.Readable = true
	c.Norm = strings.ToUpper(cert.SerialNumber.Text(16))
	for _, usage := range cert.ExtKeyUsage {
		if usage == x509.ExtKeyUsageServerAuth {
			c.ServerAuth = true
		}
	}
	return c
}

// ErrCRLSerial is a CRL that names a serial no CA could have given.
var ErrCRLSerial = errors.New("malformed serial in CRL")

// CRLSerials reads the serials a CRL file revokes, in its order, as NormSerial gives them. Whether this CA signed
// it, and its dates, the caller has checked with openssl before.
func CRLSerials(path string) ([]string, error) {
	der, err := readPEM(path, "X509 CRL")
	if err != nil {
		return nil, err
	}
	list, err := x509.ParseRevocationList(der)
	if err != nil {
		return nil, err
	}
	serials := make([]string, 0, len(list.RevokedCertificateEntries))
	for _, entry := range list.RevokedCertificateEntries {
		if entry.SerialNumber == nil || entry.SerialNumber.Sign() < 0 {
			return nil, ErrCRLSerial
		}
		serials = append(serials, strings.ToUpper(entry.SerialNumber.Text(16)))
	}
	return serials, nil
}
