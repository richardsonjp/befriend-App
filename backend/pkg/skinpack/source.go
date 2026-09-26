// Package skinpack builds a character skin from an artist's folder of PNG frames. Names are the files: whatever
// actions and moods the folders hold is what the skin can do, and nothing else lists them.
//
// Folder layout (skins/<id>/, the folder name is the id):
//
//	skin.json                        {"name": "Ghost", "fps": 8}
//	actions/<action>/<n>.png         32×32 frames played 0, 1, 2…; plays in any mood
//	actions/<action>/<mood>/<n>.png  that action in that mood only (faces are drawn into the frames)
//	mini/default.png                 16×16 head for the Dynamic Island and menu bar
//	mini/<mood>.png                  one per mood found under actions/
//
// Plain idle, walk and jump are required. Frame 0 is the still widgets show; repeat an image to hold a pose.
package skinpack

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	Size        = 32 // action frames are Size×Size pixels
	MiniSize    = 16 // heads are MiniSize×MiniSize
	maxFPS      = 30
	DefaultMini = "default" // the head shown when the skin has no face for the mood; not a mood name
)

// Required are the plain actions every skin draws: the rest pose, the Mac's walk cycle and its menu-bar hop.
var Required = []string{"idle", "walk", "jump"}

var (
	idPattern    = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)
	NamePattern  = regexp.MustCompile(`^[a-z][a-z0-9_]{0,23}$`) // action and mood names; they reach the AI prompt
	framePattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,3})\.png$`)
)

type meta struct {
	Name string `json:"name"`
	FPS  int    `json:"fps"`
}

type source struct {
	id    string
	meta  meta
	clips map[string][][]byte // "wave" or "wave/grumpy" → re-encoded frames in play order
	moods []string            // sorted
	minis map[string][]byte   // "default" and every mood
}

func load(dir string) (*source, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	src := &source{id: filepath.Base(abs), clips: map[string][][]byte{}, minis: map[string][]byte{}}
	if !idPattern.MatchString(src.id) {
		return nil, fmt.Errorf("folder name %q is the skin id: use 1-40 of a-z, 0-9 and -", src.id)
	}
	files, dirs, err := list(abs)
	if err != nil {
		return nil, err
	}
	if extra := without(append(files, dirs...), "skin.json", "actions", "mini"); len(extra) > 0 {
		return nil, fmt.Errorf("%s: only skin.json, actions/ and mini/ belong here", extra[0])
	}
	for _, want := range [][2]string{{"skin.json", "skin.json"}, {"actions", "actions/"}, {"mini", "mini/"}} {
		if !slices.Contains(files, want[0]) && !slices.Contains(dirs, want[0]) {
			return nil, fmt.Errorf("%s is missing", want[1])
		}
	}
	if src.meta, err = readMeta(filepath.Join(abs, "skin.json")); err != nil {
		return nil, err
	}
	if err := src.loadActions(filepath.Join(abs, "actions")); err != nil {
		return nil, err
	}
	return src, src.loadMinis(filepath.Join(abs, "mini"))
}

func readMeta(path string) (meta, error) {
	var m meta
	raw, err := os.ReadFile(path)
	if err != nil {
		return m, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&m); err != nil {
		return m, fmt.Errorf("skin.json: %w", err)
	}
	switch {
	case strings.TrimSpace(m.Name) == "" || utf8.RuneCountInString(m.Name) > 40:
		return m, fmt.Errorf("skin.json: name must be 1-40 characters")
	case m.FPS < 1 || m.FPS > maxFPS:
		return m, fmt.Errorf("skin.json: fps must be 1-%d", maxFPS)
	}
	return m, nil
}

// loadActions reads actions/<action>/ (plain frames) and actions/<action>/<mood>/ (frames for that mood).
func (s *source) loadActions(dir string) error {
	_, actions, err := list(dir)
	if err != nil {
		return err
	}
	moods := map[string]bool{}
	for _, action := range actions {
		if err := checkName("actions/"+action, action); err != nil {
			return err
		}
		frames, variants, err := readFrames(filepath.Join(dir, action), "actions/"+action, true)
		if err != nil {
			return err
		}
		if len(frames) > 0 {
			s.clips[action] = frames
		}
		for _, mood := range variants {
			path := "actions/" + action + "/" + mood
			if err := checkName(path, mood); err != nil {
				return err
			}
			if mood == DefaultMini {
				return fmt.Errorf("%s: %q is reserved; put mood-less frames straight in actions/%s/", path, mood, action)
			}
			if s.clips[action+"/"+mood], _, err = readFrames(filepath.Join(dir, action, mood), path, false); err != nil {
				return err
			}
			moods[mood] = true
		}
	}
	for _, action := range Required {
		if s.clips[action] == nil {
			return fmt.Errorf("actions/%s/0.png is missing: every skin draws a plain %s", action, strings.Join(Required, ", "))
		}
	}
	for mood := range moods {
		s.moods = append(s.moods, mood)
	}
	slices.Sort(s.moods)
	return nil
}

// readFrames reads a clip's 0.png, 1.png…; allowMoods lets it hold mood folders too, returned by name.
func readFrames(dir, rel string, allowMoods bool) ([][]byte, []string, error) {
	files, dirs, err := list(dir)
	if err != nil {
		return nil, nil, err
	}
	if len(dirs) > 0 && !allowMoods {
		return nil, nil, fmt.Errorf("%s/%s: mood folders hold frames only", rel, dirs[0])
	}
	count := 0
	for _, name := range files {
		if !framePattern.MatchString(name) {
			return nil, nil, fmt.Errorf("%s/%s: frames are named 0.png, 1.png, 2.png…", rel, name)
		}
		count++
	}
	if count == 0 && len(dirs) == 0 {
		return nil, nil, fmt.Errorf("%s has no frames", rel)
	}
	frames := make([][]byte, count)
	for i := range frames {
		name := strconv.Itoa(i) + ".png"
		if !slices.Contains(files, name) {
			return nil, nil, fmt.Errorf("%s/%s is missing: frames must count up from 0 with no gaps", rel, name)
		}
		if frames[i], err = readPNG(filepath.Join(dir, name), rel+"/"+name, Size); err != nil {
			return nil, nil, err
		}
	}
	return frames, dirs, nil
}

func (s *source) loadMinis(dir string) error {
	files, dirs, err := list(dir)
	if err != nil {
		return err
	}
	if len(dirs) > 0 {
		return fmt.Errorf("mini/%s: mini/ holds <mood>.png files only", dirs[0])
	}
	for _, name := range files {
		mood := strings.TrimSuffix(name, ".png")
		if mood == name || (mood != DefaultMini && !slices.Contains(s.moods, mood)) {
			return fmt.Errorf("mini/%s: no mood folder under actions/ is named %q", name, mood)
		}
		if s.minis[mood], err = readPNG(filepath.Join(dir, name), "mini/"+name, MiniSize); err != nil {
			return err
		}
	}
	for _, mood := range append([]string{DefaultMini}, s.moods...) {
		if s.minis[mood] == nil {
			return fmt.Errorf("mini/%s.png is missing", mood)
		}
	}
	return nil
}

// readPNG checks the size before decoding (uploads are untrusted) and re-encodes the pixels, dropping metadata so
// the same art always packs to the same bytes.
func readPNG(path, rel string, size int) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(raw))
	switch {
	case err != nil || format != "png":
		return nil, fmt.Errorf("%s is not a PNG", rel)
	case config.Width != size || config.Height != size:
		return nil, fmt.Errorf("%s is %d×%d; want %d×%d", rel, config.Width, config.Height, size, size)
	}
	decoded, err := png.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", rel, err)
	}
	img := image.NewNRGBA(decoded.Bounds())
	draw.Draw(img, img.Bounds(), decoded, decoded.Bounds().Min, draw.Src)
	var buf bytes.Buffer
	err = (&png.Encoder{CompressionLevel: png.BestCompression}).Encode(&buf, img)
	return buf.Bytes(), err
}

// list returns a folder's files and subfolders, sorted, skipping hidden entries like .DS_Store.
func list(dir string) (files, dirs []string, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, err
	}
	for _, e := range entries {
		switch {
		case strings.HasPrefix(e.Name(), "."):
		case e.IsDir():
			dirs = append(dirs, e.Name())
		case e.Type().IsRegular():
			files = append(files, e.Name())
		default:
			return nil, nil, fmt.Errorf("%s is not a regular file", e.Name())
		}
	}
	return files, dirs, nil
}

func checkName(rel, name string) error {
	if !NamePattern.MatchString(name) {
		return fmt.Errorf("%s: names are 1-24 of a-z, 0-9 and _, starting with a letter", rel)
	}
	return nil
}

func without(names []string, allowed ...string) []string {
	return slices.DeleteFunc(names, func(n string) bool { return slices.Contains(allowed, n) })
}
