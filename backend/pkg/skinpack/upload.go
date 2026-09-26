package skinpack

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// Limits on an artist's upload: the source folder, zipped. They're checked while reading, not trusted from the
// zip's headers, which could lie.
const (
	MaxUploadBytes    = 4 << 20 // Fiber's default body limit, kept for every route; a full skin zips to ~0.5 MB
	maxUploadEntries  = 5000
	maxUploadFile     = 1 << 20 // a 32×32 PNG is a few hundred bytes
	maxUploadUnpacked = 32 << 20
)

// FromUpload builds a skin from an uploaded zip of its folder (skin.json, actions/, mini/ at the top, or inside
// one folder). id is the skin id the artist asked for; the folder name inside the zip doesn't matter.
func FromUpload(data []byte, id string) (*Package, error) {
	if len(data) > MaxUploadBytes {
		return nil, fmt.Errorf("the zip is %d bytes; at most %d", len(data), MaxUploadBytes)
	}
	if !idPattern.MatchString(id) {
		return nil, fmt.Errorf("skin id %q: use 1-40 of a-z, 0-9 and -", id)
	}
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("not a zip file")
	}
	if len(r.File) > maxUploadEntries {
		return nil, fmt.Errorf("the zip has %d entries; at most %d", len(r.File), maxUploadEntries)
	}

	tmp, err := os.MkdirTemp("", "skin-upload-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	dir := filepath.Join(tmp, id)
	if err := unpack(r.File, dir); err != nil {
		return nil, err
	}
	return Build(dir)
}

func unpack(files []*zip.File, dir string) error {
	root := commonRoot(files)
	unpacked := 0
	for _, f := range files {
		name, ok := strings.CutPrefix(f.Name, root)
		if !ok || f.FileInfo().IsDir() || skipped(name) {
			continue
		}
		clean := path.Clean(name)
		if strings.Contains(f.Name, `\`) || path.IsAbs(f.Name) || clean == ".." || strings.HasPrefix(clean, "../") {
			return fmt.Errorf("%s: not a path inside the skin folder", f.Name)
		}
		if !f.Mode().IsRegular() {
			return fmt.Errorf("%s: only plain files", name)
		}
		n, err := extract(f, filepath.Join(dir, filepath.FromSlash(clean)))
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		if unpacked += n; unpacked > maxUploadUnpacked {
			return fmt.Errorf("the skin unpacks to more than %d bytes", maxUploadUnpacked)
		}
	}
	return nil
}

func extract(f *zip.File, dest string) (int, error) {
	rc, err := f.Open()
	if err != nil {
		return 0, err
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, maxUploadFile+1))
	if err != nil {
		return 0, err
	}
	if len(data) > maxUploadFile {
		return 0, fmt.Errorf("larger than %d bytes", maxUploadFile)
	}
	// Filesystem errors carry the server's temp path; the artist only needs to know it failed.
	if os.MkdirAll(filepath.Dir(dest), 0o755) != nil || os.WriteFile(dest, data, 0o644) != nil {
		return 0, fmt.Errorf("couldn't be unpacked")
	}
	return len(data), nil
}

// commonRoot is "ghost/" when every entry sits in one folder (zipping the folder itself), else "".
func commonRoot(files []*zip.File) string {
	root := ""
	for _, f := range files {
		if skipped(f.Name) {
			continue
		}
		first, rest, nested := strings.Cut(f.Name, "/")
		if !nested || first == "skin.json" || (root != "" && root != first+"/") {
			return ""
		}
		if rest == "" && !f.FileInfo().IsDir() {
			return ""
		}
		root = first + "/"
	}
	return root
}

// skipped are the files zip tools add on their own: macOS resource forks and hidden files.
func skipped(name string) bool {
	if strings.HasPrefix(name, "__MACOSX/") {
		return true
	}
	for _, part := range strings.Split(name, "/") {
		if strings.HasPrefix(part, ".") && part != "." && part != ".." {
			return true
		}
	}
	return false
}
