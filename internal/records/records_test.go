package records

import (
	"bytes"
	"errors"
	"testing"
)

func TestWriteJoinsFieldsWithTabs(t *testing.T) {
	var out bytes.Buffer
	w := NewWriter(&out)
	w.Write("row", "1", "alice")
	w.Write("hidden", "3")
	if out.Len() != 0 {
		t.Fatalf("records reached the output before Flush: %q", out.String())
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	if got, want := out.String(), "row\t1\talice\nhidden\t3\n"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestFieldsBashCannotReadAreRefused(t *testing.T) {
	for _, field := range []string{"", "a\tb", "a\nb", "a\x00b"} {
		var out bytes.Buffer
		w := NewWriter(&out)
		w.Write("row", field)
		w.Write("later", "x")
		if err := w.Flush(); !errors.Is(err, ErrField) {
			t.Fatalf("field %q: got %v, want ErrField", field, err)
		}
		if out.Len() != 0 {
			t.Fatalf("field %q: a failed list printed %q", field, out.String())
		}
	}
}

func TestNoFieldsIsRefused(t *testing.T) {
	w := NewWriter(&bytes.Buffer{})
	w.Write()
	if !errors.Is(w.Err(), ErrField) {
		t.Fatalf("got %v, want ErrField", w.Err())
	}
}
