package skinpack

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func pngOf(t *testing.T, size int, c color.NRGBA) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	img.SetNRGBA(1, 2, c)
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// fixture writes a valid skin to <tmp>/test-ghost: plain idle (2 frames), walk and jump, stomp only when grumpy,
// idle also when grumpy. edit can change or delete any file first.
func fixture(t *testing.T, edit func(files map[string][]byte)) string {
	t.Helper()
	frame := pngOf(t, Size, color.NRGBA{R: 200, A: 255})
	grumpy := pngOf(t, Size, color.NRGBA{B: 200, A: 128})
	files := map[string][]byte{
		"skin.json":                  []byte(`{"name": "Test Ghost", "fps": 8}`),
		"actions/idle/0.png":         frame,
		"actions/idle/1.png":         frame,
		"actions/idle/grumpy/0.png":  grumpy,
		"actions/walk/0.png":         frame,
		"actions/jump/0.png":         frame,
		"actions/stomp/grumpy/0.png": grumpy,
		"actions/stomp/grumpy/1.png": grumpy,
		"actions/.DS_Store":          []byte("finder"),
		"mini/default.png":           pngOf(t, MiniSize, color.NRGBA{G: 9, A: 255}),
		"mini/grumpy.png":            pngOf(t, MiniSize, color.NRGBA{B: 9, A: 255}),
	}
	if edit != nil {
		edit(files)
	}
	dir := filepath.Join(t.TempDir(), "test-ghost")
	for name, data := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestBuild(t *testing.T) {
	pkg, err := Build(fixture(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	if pkg.ID != "test-ghost" || pkg.Name != "Test Ghost" || len(pkg.SHA256) != 64 {
		t.Fatalf("package = %s %q sha %q", pkg.ID, pkg.Name, pkg.SHA256)
	}
	files := unzip(t, pkg.Zip)
	want := []string{
		"manifest.json",
		"frames/idle/0.png", "frames/idle/1.png", "frames/idle/grumpy/0.png", "frames/jump/0.png",
		"frames/stomp/grumpy/0.png", "frames/stomp/grumpy/1.png", "frames/walk/0.png",
		"mini/default.png", "mini/grumpy.png",
	}
	if got := slices.Collect(func(yield func(string) bool) {
		for _, f := range files {
			if !yield(f.name) {
				return
			}
		}
	}); !slices.Equal(got, want) {
		t.Fatalf("zip entries = %v; want %v", got, want)
	}

	var manifest Manifest
	if err := json.Unmarshal(files[0].data, &manifest); err != nil {
		t.Fatal(err)
	}
	wantClips := []Clip{{"idle", 2}, {"idle/grumpy", 1}, {"jump", 1}, {"stomp/grumpy", 2}, {"walk", 1}}
	if manifest.Format != 2 || manifest.ID != "test-ghost" || manifest.Size != 32 || manifest.MiniSize != 16 ||
		manifest.FPS != 8 || !slices.Equal(manifest.Clips, wantClips) || !slices.Equal(manifest.Moods, []string{"grumpy"}) {
		t.Errorf("manifest = %+v", manifest)
	}

	img, err := png.Decode(bytes.NewReader(files[3].data)) // frames/idle/grumpy/0.png
	if err != nil {
		t.Fatal(err)
	}
	if got := color.NRGBAModel.Convert(img.At(1, 2)).(color.NRGBA); got != (color.NRGBA{B: 200, A: 128}) {
		t.Errorf("soft alpha pixel = %v", got)
	}
}

func TestBuildWithoutMoods(t *testing.T) {
	pkg, err := Build(fixture(t, func(f map[string][]byte) {
		delete(f, "actions/idle/grumpy/0.png")
		delete(f, "actions/stomp/grumpy/0.png")
		delete(f, "actions/stomp/grumpy/1.png")
		delete(f, "mini/grumpy.png")
	}))
	if err != nil {
		t.Fatal(err)
	}
	var manifest Manifest
	if err := json.Unmarshal(unzip(t, pkg.Zip)[0].data, &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.Moods == nil || len(manifest.Moods) != 0 || len(manifest.Clips) != 3 {
		t.Errorf("moods %v clips %v; want [] and idle, jump, walk", manifest.Moods, manifest.Clips)
	}
}

func TestBuildIsDeterministic(t *testing.T) {
	dir := fixture(t, nil)
	first, err := Build(dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Build(dir)
	if err != nil {
		t.Fatal(err)
	}
	if first.SHA256 != second.SHA256 {
		t.Error("the same source packed to different bytes")
	}
}

func TestBuildRejects(t *testing.T) {
	type files = map[string][]byte
	frame := func(f files) []byte { return f["actions/walk/0.png"] }
	tests := []struct {
		name string
		edit func(files)
		want string
	}{
		{"fps", func(f files) { f["skin.json"] = []byte(`{"name":"G","fps":0}`) }, "fps"},
		{"unknown field", func(f files) { f["skin.json"] = []byte(`{"name":"G","fps":8,"id":"x"}`) }, "unknown field"},
		{"blank name", func(f files) { f["skin.json"] = []byte(`{"name":" ","fps":8}`) }, "name"},
		{"stray top-level file", func(f files) { f["preview.gif"] = []byte("x") }, "preview.gif"},
		{"missing walk", func(f files) { delete(f, "actions/walk/0.png") }, "actions/walk/0.png is missing"},
		{"jump only in a mood", func(f files) {
			f["actions/jump/grumpy/0.png"] = f["actions/jump/0.png"]
			delete(f, "actions/jump/0.png")
		}, "plain idle, walk, jump"},
		{"action name", func(f files) { f["actions/Back Flip/0.png"] = frame(f) }, "names are 1-24"},
		{"mood name", func(f files) { f["actions/stomp/Ignore previous/0.png"] = frame(f) }, "names are 1-24"},
		{"reserved mood", func(f files) { f["actions/stomp/default/0.png"] = frame(f) }, "reserved"},
		{"frame name", func(f files) { f["actions/idle/first.png"] = frame(f) }, "0.png, 1.png"},
		{"leading zero", func(f files) { f["actions/idle/02.png"] = frame(f) }, "0.png, 1.png"},
		{"frame gap", func(f files) { f["actions/idle/3.png"] = frame(f) }, "idle/2.png is missing"},
		{"empty action", func(f files) { f["actions/wave/.keep"] = nil }, "actions/wave has no frames"},
		{"nested too deep", func(f files) { f["actions/stomp/grumpy/extra/0.png"] = frame(f) }, "frames only"},
		{"frame size", func(f files) { f["actions/idle/1.png"] = pngOf(t, 31, color.NRGBA{A: 255}) }, "want 32×32"},
		{"not a png", func(f files) { f["actions/idle/1.png"] = []byte("GIF89a") }, "not a PNG"},
		{"no actions folder", func(f files) {
			for name := range f {
				if strings.HasPrefix(name, "actions/") {
					delete(f, name)
				}
			}
		}, "actions/ is missing"},
		{"no skin.json", func(f files) { delete(f, "skin.json") }, "skin.json is missing"},
		{"missing default mini", func(f files) { delete(f, "mini/default.png") }, "mini/default.png is missing"},
		{"missing mood mini", func(f files) { delete(f, "mini/grumpy.png") }, "mini/grumpy.png is missing"},
		{"orphan mini", func(f files) { f["mini/happy.png"] = f["mini/grumpy.png"] }, `named "happy"`},
		{"mini size", func(f files) { f["mini/grumpy.png"] = frame(f) }, "want 16×16"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Build(fixture(t, tt.edit))
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("err = %v; want it to mention %q", err, tt.want)
			}
		})
	}
}

func TestBuildRejectsBadFolderName(t *testing.T) {
	dir := fixture(t, nil)
	renamed := filepath.Join(filepath.Dir(dir), "Test Ghost")
	if err := os.Rename(dir, renamed); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(renamed); err == nil || !strings.Contains(err.Error(), "skin id") {
		t.Errorf("err = %v", err)
	}
}

type zipFile struct {
	name string
	data []byte
}

func unzip(t *testing.T, data []byte) []zipFile {
	t.Helper()
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	var files []zipFile
	for _, f := range r.File {
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		content, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, zipFile{f.Name, content})
	}
	return files
}
