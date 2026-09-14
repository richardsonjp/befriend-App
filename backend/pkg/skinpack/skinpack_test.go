package skinpack

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"befriend/pkg/utils/vocabulary"
)

const (
	bodyColor = 0xf4a340
	faceColor = 0x1b1b1b
)

// fixture writes a valid skin (two frames per action, sleep's still hiding the face) to a temp folder. edit can
// change the decoded meta.json or any file first.
func fixture(t *testing.T, edit func(meta map[string]any, files map[string]string)) string {
	t.Helper()
	body := gridText(Size, Size, func(x, y int) byte {
		switch {
		case x == 10 && y == 12:
			return '@'
		case y >= 8:
			return 'o'
		default:
			return '.'
		}
	})
	actions := map[string]any{}
	files := map[string]string{}
	for _, action := range vocabulary.Actions {
		actions[action] = map[string]any{"frames": []string{action + "/0", action + "/1"}, "still": 1}
		files["body/"+action+"/0.txt"] = body
		files["body/"+action+"/1.txt"] = body
	}
	files["body/sleep/1.txt"] = strings.ReplaceAll(body, "@", "o")
	for _, mood := range vocabulary.Moods {
		files["face/"+mood+".txt"] = gridText(6, 3, func(_, y int) byte { return map[bool]byte{true: 'k', false: '.'}[y == 1] })
		files["mini/"+mood+".txt"] = gridText(MiniSize, MiniSize, func(int, int) byte { return 'o' })
	}
	meta := map[string]any{
		"id": "test-cat", "name": "Test Cat", "fps": 8, "face_base": "o",
		"palette": map[string]any{"o": "#f4a340", "k": "#1b1b1b"}, "actions": actions,
	}
	if edit != nil {
		edit(meta, files)
	}
	raw, err := json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	files["meta.json"] = string(raw)

	dir := t.TempDir()
	for name, text := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func gridText(w, h int, cell func(x, y int) byte) string {
	var b strings.Builder
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			b.WriteByte(cell(x, y))
		}
		b.WriteByte('\n')
	}
	return b.String()
}

func TestBuild(t *testing.T) {
	pkg, err := Build(fixture(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	if pkg.ID != "test-cat" || pkg.Name != "Test Cat" || len(pkg.SHA256) != 64 {
		t.Fatalf("package = %s %q sha %q", pkg.ID, pkg.Name, pkg.SHA256)
	}
	files := unzip(t, pkg.Zip)
	if want := 2 + len(vocabulary.Moods)*(1+len(vocabulary.Actions)); len(files) != want {
		t.Fatalf("%d files; want %d", len(files), want)
	}

	var manifest Manifest
	if err := json.Unmarshal(files["manifest.json"], &manifest); err != nil {
		t.Fatal(err)
	}
	want := Manifest{Format: 1, ID: "test-cat", Name: "Test Cat", VocabularyVersion: vocabulary.Version, Size: 32, MiniSize: 16, FPS: 8}
	if manifest != want {
		t.Errorf("manifest = %+v", manifest)
	}

	var animation struct {
		Op, W   int
		Markers []struct {
			Cm     string
			Tm, Dr int
		}
		Layers []struct {
			Nm  string
			Ty  int
			Ind int
			Ks  map[string]json.RawMessage
		}
	}
	if err := json.Unmarshal(files["skin.json"], &animation); err != nil {
		t.Fatal(err)
	}
	// two frames per action plus the frame lottie-ios lands on at a marker's end
	if animation.Op != 60 || animation.W != 32 || len(animation.Markers) != 20 || len(animation.Layers) != 12+40 {
		t.Fatalf("op %d, w %d, %d markers, %d layers", animation.Op, animation.W, len(animation.Markers), len(animation.Layers))
	}
	for i, m := range animation.Markers {
		if m.Cm != vocabulary.Actions[i] || m.Tm != 3*i || m.Dr != 2 {
			t.Errorf("marker %d = %+v", i, m)
		}
	}
	for i, mood := range vocabulary.Moods {
		layer := animation.Layers[i]
		opacity := `{"a":0,"k":0}`
		if mood == "content" {
			opacity = `{"a":0,"k":100}`
		}
		if layer.Nm != FaceLayerName(mood) || layer.Ty != 4 || layer.Ind != i+1 || string(layer.Ks["o"]) != opacity {
			t.Errorf("layer %d = %s type %d ind %d opacity %s", i, layer.Nm, layer.Ty, layer.Ind, layer.Ks["o"])
		}
	}
	// sleep is the fourth action (timeline 9-11): its face-less second frame and the end frame after it hide the face
	if scale := string(animation.Layers[0].Ks["s"]); !strings.Contains(scale, `{"h":1,"s":[0,0,100],"t":10},{"h":1,"s":[100,100,100],"t":12}`) {
		t.Errorf("face scale doesn't hide it on sleep's frame: %s", scale)
	}

	still := decodePNG(t, files["stills/wave/grumpy.png"])
	checkPixel(t, "face", still, 10, 13, faceColor)
	checkPixel(t, "'@' painted as face_base", still, 10, 12, bodyColor)
	if _, _, _, a := still.At(0, 0).RGBA(); a != 0 || still.Bounds().Dx() != Size {
		t.Errorf("still is %v wide with alpha %d at the top-left", still.Bounds().Dx(), a)
	}
	checkPixel(t, "sleep hides the face", decodePNG(t, files["stills/sleep/grumpy.png"]), 10, 13, bodyColor)
	if mini := decodePNG(t, files["mini/calm.png"]); mini.Bounds().Dx() != MiniSize {
		t.Errorf("mini is %d wide", mini.Bounds().Dx())
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
	type files = map[string]string
	type meta = map[string]any
	setAction := func(name string, frames []string, still int) func(meta, files) {
		return func(m meta, _ files) {
			m["actions"].(map[string]any)[name] = map[string]any{"frames": frames, "still": still}
		}
	}
	tests := []struct {
		name string
		edit func(meta, files)
		want string
	}{
		{"id", func(m meta, _ files) { m["id"] = "Test Cat" }, "id"},
		{"fps", func(m meta, _ files) { m["fps"] = 0 }, "fps"},
		{"unknown field", func(m meta, _ files) { m["colour"] = "red" }, "unknown field"},
		{"palette colour", func(m meta, _ files) { m["palette"].(map[string]any)["k"] = "black" }, "#rrggbb"},
		{"face base", func(m meta, _ files) { m["face_base"] = "z" }, "face_base"},
		{"missing action", func(m meta, _ files) { delete(m["actions"].(map[string]any), "love") }, `"love" is missing`},
		{"unknown action", setAction("moonwalk", []string{"wave/0"}, 0), "moonwalk"},
		{"still index", setAction("wave", []string{"wave/0"}, 1), "still 1"},
		{"frame name", setAction("wave", []string{"../wave/0"}, 0), "frame name"},
		{"ragged grid", func(_ meta, f files) { f["body/wave/0.txt"] = strings.Replace(f["body/wave/0.txt"], "..", ".", 1) }, "wide"},
		{"unknown key", func(_ meta, f files) { f["body/wave/0.txt"] = strings.Replace(f["body/wave/0.txt"], ".", "x", 1) }, "not in the palette"},
		{"two origins", func(_ meta, f files) { f["body/wave/0.txt"] = strings.Replace(f["body/wave/0.txt"], ".", "@", 1) }, "more than one '@'"},
		{"missing face", func(_ meta, f files) { delete(f, "face/shy.txt") }, "shy.txt"},
		{"mini size", func(_ meta, f files) { f["mini/shy.txt"] = gridText(15, 16, func(int, int) byte { return 'o' }) }, "want 16×16"},
		{"face off canvas", func(_ meta, f files) { f["face/shy.txt"] = gridText(30, 3, func(int, int) byte { return 'k' }) }, "off the canvas"},
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

func TestRectsMergeRunsDownward(t *testing.T) {
	g := &grid{w: 3, h: 3, cells: []byte("oo." + "oo." + "ok.")}
	want := []rect{{0, 0, 2, 2, 'o'}, {0, 2, 1, 1, 'o'}, {1, 2, 1, 1, 'k'}}
	if got := rects(g); !slices.Equal(got, want) {
		t.Errorf("rects = %v; want %v", got, want)
	}
}

func unzip(t *testing.T, data []byte) map[string][]byte {
	t.Helper()
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{}
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
		files[f.Name] = content
	}
	return files
}

func decodePNG(t *testing.T, data []byte) image.Image {
	t.Helper()
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	return img
}

func checkPixel(t *testing.T, what string, img image.Image, x, y int, rgb uint32) {
	t.Helper()
	r, g, b, a := img.At(x, y).RGBA()
	if got := (r>>8)<<16 | (g>>8)<<8 | b>>8; got != rgb || a != 0xffff {
		t.Errorf("%s: pixel (%d,%d) = #%06x alpha %d; want #%06x", what, x, y, got, a, rgb)
	}
}
