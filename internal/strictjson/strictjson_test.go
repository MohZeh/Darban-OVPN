package strictjson

import (
	"errors"
	"strings"
	"testing"
)

type inner struct {
	Port int `json:"port"`
}

type request struct {
	Scope  string            `json:"scope"`
	Names  []string          `json:"names,omitempty"`
	Inner  *inner            `json:"inner,omitempty"`
	List   []inner           `json:"list,omitempty"`
	Labels map[string]string `json:"labels,omitempty"`
	Kind   string            `json:"kind,omitempty"`
	Hidden string            `json:"-"`
}

var errEmptyScope = errors.New("scope is empty")

func (r *request) Validate() error {
	if r.Scope == "" {
		return errEmptyScope
	}
	return nil
}

func TestAGoodDocumentIsDecodedAndValidated(t *testing.T) {
	// The keys of a map are data: "X" and "x" are two keys, unlike the fields of a struct.
	var r request
	err := Decode([]byte(`{"scope":"clients","names":["a"],"inner":{"port":1194},"list":[{"port":1}],"labels":{"X":"1","x":"2"}}`), &r)
	if err != nil {
		t.Fatal(err)
	}
	if r.Scope != "clients" || r.Inner.Port != 1194 || r.List[0].Port != 1 || r.Labels["X"] != "1" || r.Labels["x"] != "2" {
		t.Fatalf("decoded %+v", r)
	}
}

func TestRefused(t *testing.T) {
	cases := map[string]struct{ doc, want string }{
		"unknown field":               {`{"scope":"a","extra":1}`, "unknown key"},
		"unknown nested field":        {`{"scope":"a","inner":{"port":1,"host":"x"}}`, "unknown key"},
		"unknown field in a list":     {`{"scope":"a","list":[{"port":1},{"Port":2}]}`, `differs only in case from the field "port"`},
		"duplicate key":               {`{"scope":"a","scope":"b"}`, "the key appears twice"},
		"keys differing only in case": {`{"scope":"a","Scope":"b"}`, `differs only in case from "scope"`},
		"a key in another case":       {`{"SCOPE":"a"}`, `differs only in case from the field "scope"`},
		"the Kelvin sign for k":       {`{"scope":"a","\u212aind":"x"}`, `differs only in case from the field "kind"`},
		"a map key twice":             {`{"scope":"a","labels":{"x":"1","x":"2"}}`, "the key appears twice"},
		"a field that is never JSON":  {`{"scope":"a","Hidden":"x"}`, "unknown key"},
		"two values":                  {`{"scope":"a"} {"scope":"b"}`, "more than one JSON value"},
		"not an object":               {`["scope"]`, "cannot unmarshal"},
		"not JSON":                    {`{"scope":`, "EOF"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			var r request
			err := Decode([]byte(c.doc), &r)
			if err == nil || !IsRefused(err) || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want a refusal with %q", err, c.want)
			}
		})
	}
}

func TestTheCheckedValueIsTheOneValidated(t *testing.T) {
	var r request
	err := Decode([]byte(`{"scope":""}`), &r)
	if !errors.Is(err, errEmptyScope) {
		t.Fatalf("got %v, want the Validate error", err)
	}
	if IsRefused(err) {
		t.Fatal("a Validate error is not a refusal of the document")
	}
}

func TestTheTargetMustBeAStructPointer(t *testing.T) {
	var m map[string]any
	if err := Decode([]byte(`{}`), &m); !IsRefused(err) {
		t.Fatalf("got %v, want a refusal", err)
	}
}

func TestReadRefusesALargeDocument(t *testing.T) {
	var r request
	doc := `{"scope":"` + strings.Repeat("a", MaxSize) + `"}`
	if err := Read(strings.NewReader(doc), &r); !IsRefused(err) {
		t.Fatalf("got %v, want a refusal", err)
	}
}
