package skinpack

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// zipped zips a folder's files under prefix ("" or "ghost/"), plus extra entries.
func zipped(t *testing.T, dir, prefix string, extra map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	add := func(name string, data []byte) {
		f, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		data, err := os.ReadFile(p)
		add(prefix+filepath.ToSlash(rel), data)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range extra {
		add(name, data)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestFromUpload(t *testing.T) {
	dir := fixture(t, nil)
	for _, prefix := range []string{"", "Ghost Art/"} {
		upload := zipped(t, dir, prefix, map[string][]byte{"__MACOSX/._skin.json": []byte("fork")})
		pkg, err := FromUpload(upload, "ghost")
		if err != nil {
			t.Fatalf("prefix %q: %v", prefix, err)
		}
		if pkg.ID != "ghost" || pkg.Name != "Test Ghost" || len(pkg.Clips) != 6 {
			t.Errorf("prefix %q: package = %s %q %d clips", prefix, pkg.ID, pkg.Name, len(pkg.Clips))
		}
	}
}

func TestFromUploadRejects(t *testing.T) {
	dir := fixture(t, nil)
	big := bytes.Repeat([]byte{0}, maxUploadFile+1)
	tests := []struct {
		name string
		data []byte
		id   string
		want string
	}{
		{"not a zip", []byte("PK nope"), "ghost", "not a zip"},
		{"bad id", zipped(t, dir, "", nil), "Ghost!", "skin id"},
		{"too big", make([]byte, MaxUploadBytes+1), "ghost", "at most"},
		{"escaping path", zipped(t, dir, "", map[string][]byte{"../evil.png": {1}}), "ghost", "not a path inside"},
		{"backslash path", zipped(t, dir, "", map[string][]byte{`actions\x.png`: {1}}), "ghost", "not a path inside"},
		{"huge file", zipped(t, dir, "", map[string][]byte{"actions/idle/9.png": big}), "ghost", "larger than"},
		{"invalid skin", zipped(t, dir, "", map[string][]byte{"notes.txt": []byte("hi")}), "ghost", "notes.txt"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := FromUpload(tt.data, tt.id)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("err = %v; want it to mention %q", err, tt.want)
			}
		})
	}
}
