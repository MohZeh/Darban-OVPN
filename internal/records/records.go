// Package records writes what darban-core hands to the manager in Bash: one record per line, its fields separated
// by a tab. Bash reads a record with IFS=$'\t' read -r, which treats a tab as white space: two tabs in a row would
// lose an empty field and shift the others. So a field is never empty, and never holds a tab, a line break or NUL.
// G4 adds NUL-separated records on fd 3 for its actions; these lines are for the screens that read the CA.
package records

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strings"
)

// ErrField is returned for a field Bash could not read back as written.
var ErrField = errors.New("a record field is empty or holds a tab, a line break or NUL")

// Valid reports whether one field can be written.
func Valid(field string) bool {
	return field != "" && !strings.ContainsAny(field, "\t\n\x00")
}

// Writer buffers records. Nothing reaches the output before Flush, so a command that fails half way prints no
// partial list: the caller exits with an error instead, and Bash never sees a list that looks complete.
type Writer struct {
	buf *bufio.Writer
	err error
}

// NewWriter returns a Writer to w.
func NewWriter(w io.Writer) *Writer {
	return &Writer{buf: bufio.NewWriterSize(w, 1<<20)}
}

// Write adds one record. The first error is kept, and later records are ignored.
func (w *Writer) Write(fields ...string) {
	if w.err != nil {
		return
	}
	if len(fields) == 0 {
		w.err = ErrField
		return
	}
	for _, field := range fields {
		if !Valid(field) {
			w.err = fmt.Errorf("%w: %q", ErrField, field)
			return
		}
	}
	_, w.err = w.buf.WriteString(strings.Join(fields, "\t") + "\n")
}

// Err is the first error of Write.
func (w *Writer) Err() error { return w.err }

// Flush writes the records out, unless a Write failed.
func (w *Writer) Flush() error {
	if w.err != nil {
		return w.err
	}
	return w.buf.Flush()
}
