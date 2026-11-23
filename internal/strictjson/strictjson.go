// Package strictjson is the one way darban-core reads JSON (rule H2): into a typed struct, with every key checked
// first, and the same value that was checked is the one the caller uses.
//
// encoding/json alone accepts more than that. It ignores an unknown key, keeps the last of two equal keys, and
// matches a key to a field without regard to case, so {"scope": "a", "Scope": "b"} or {"SCOPE": "b"} would both
// fill the field "scope". Decode refuses each of these before anything is decoded.
package strictjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
	"unicode"
	"unicode/utf8"
)

// MaxSize is the most Decode reads.
const MaxSize = 1 << 20

// Validator is implemented by a type that checks its own values once decoded. Decode calls it on the value it
// filled, so what was validated is what the caller then uses.
type Validator interface {
	Validate() error
}

// Error is the reason a document was refused.
type Error struct {
	Path   string
	Reason string
}

func (e *Error) Error() string {
	if e.Path == "" {
		return "json: " + e.Reason
	}
	return "json: " + e.Path + ": " + e.Reason
}

// Read decodes one JSON document from r into v, as Decode does.
func Read(r io.Reader, v any) error {
	data, err := io.ReadAll(io.LimitReader(r, MaxSize+1))
	if err != nil {
		return err
	}
	if len(data) > MaxSize {
		return &Error{Reason: fmt.Sprintf("larger than %d bytes", MaxSize)}
	}
	return Decode(data, v)
}

// Decode fills v, a pointer to a struct, from data. It refuses a document that is not one JSON value, a key the
// type does not have, a key that matches a field only when case is ignored, and an object that holds the same
// key twice, or two keys that differ only in case. Then, if v is a Validator, it calls Validate.
func Decode(data []byte, v any) error {
	target := reflect.TypeOf(v)
	if target == nil || target.Kind() != reflect.Pointer || target.Elem().Kind() != reflect.Struct {
		return &Error{Reason: "the target must be a pointer to a struct"}
	}
	if !utf8.Valid(data) {
		return &Error{Reason: "not valid UTF-8"}
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := checkValue(dec, target.Elem(), "$"); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return &Error{Reason: "more than one JSON value"}
	}
	strict := json.NewDecoder(bytes.NewReader(data))
	strict.DisallowUnknownFields()
	if err := strict.Decode(v); err != nil {
		return &Error{Reason: err.Error()}
	}
	if checker, ok := v.(Validator); ok {
		if err := checker.Validate(); err != nil {
			return err
		}
	}
	return nil
}

// fold is the key under which encoding/json would match a name: equal for names that differ only in case.
func fold(name string) string {
	var b strings.Builder
	for _, r := range name {
		// The smallest rune of its case orbit, so K, k and the Kelvin sign fold alike.
		low := r
		for next := unicode.SimpleFold(r); next != r; next = unicode.SimpleFold(next) {
			if next < low {
				low = next
			}
		}
		b.WriteRune(low)
	}
	return b.String()
}

// fieldNames maps each JSON name of a struct's fields to the field's type, as encoding/json sees them: tags, and
// the fields of embedded structs.
func fieldNames(t reflect.Type) map[string]reflect.Type {
	names := map[string]reflect.Type{}
	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		tag := field.Tag.Get("json")
		if tag == "-" {
			continue
		}
		name, _, _ := strings.Cut(tag, ",")
		if field.Anonymous && name == "" {
			embedded := field.Type
			if embedded.Kind() == reflect.Pointer {
				embedded = embedded.Elem()
			}
			if embedded.Kind() == reflect.Struct {
				for inner, innerType := range fieldNames(embedded) {
					if _, taken := names[inner]; !taken {
						names[inner] = innerType
					}
				}
				continue
			}
		}
		if !field.IsExported() {
			continue
		}
		if name == "" {
			name = field.Name
		}
		names[name] = field.Type
	}
	return names
}

func checkValue(dec *json.Decoder, t reflect.Type, path string) error {
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	token, err := dec.Token()
	if err != nil {
		return &Error{Path: path, Reason: err.Error()}
	}
	delim, isDelim := token.(json.Delim)
	if !isDelim {
		return nil
	}
	switch delim {
	case '{':
		return checkObject(dec, t, path)
	case '[':
		elem := t
		if t.Kind() == reflect.Slice || t.Kind() == reflect.Array {
			elem = t.Elem()
		}
		for i := 0; dec.More(); i++ {
			if err := checkValue(dec, elem, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
		_, err := dec.Token()
		return err
	}
	return &Error{Path: path, Reason: "unexpected " + delim.String()}
}

func checkObject(dec *json.Decoder, t reflect.Type, path string) error {
	var fields map[string]reflect.Type
	if t.Kind() == reflect.Struct {
		fields = fieldNames(t)
	}
	folded := map[string]string{}
	for name := range fields {
		folded[fold(name)] = name
	}
	seen := map[string]string{}
	for dec.More() {
		token, err := dec.Token()
		if err != nil {
			return &Error{Path: path, Reason: err.Error()}
		}
		key, ok := token.(string)
		if !ok {
			return &Error{Path: path, Reason: "an object key that is not a string"}
		}
		where := path + "." + key
		// The keys of a struct are matched to its fields without regard to case, so two that differ only in case
		// would fill one field. The keys of a map are data, matched exactly: "X" and "x" are two keys there.
		same := key
		if t.Kind() == reflect.Struct {
			same = fold(key)
		}
		if earlier, dup := seen[same]; dup {
			if earlier == key {
				return &Error{Path: where, Reason: "the key appears twice"}
			}
			return &Error{Path: where, Reason: fmt.Sprintf("the key differs only in case from %q", earlier)}
		}
		seen[same] = key
		next := reflect.TypeOf((*any)(nil)).Elem()
		switch t.Kind() {
		case reflect.Struct:
			fieldType, exact := fields[key]
			if !exact {
				if name, near := folded[fold(key)]; near {
					return &Error{Path: where, Reason: fmt.Sprintf("the key differs only in case from the field %q", name)}
				}
				return &Error{Path: where, Reason: "unknown key"}
			}
			next = fieldType
		case reflect.Map:
			next = t.Elem()
		}
		if err := checkValue(dec, next, where); err != nil {
			return err
		}
	}
	if _, err := dec.Token(); err != nil {
		return &Error{Path: path, Reason: err.Error()}
	}
	return nil
}

// IsRefused reports whether err is a refusal by this package, not a Validate error.
func IsRefused(err error) bool {
	var refused *Error
	return errors.As(err, &refused)
}
