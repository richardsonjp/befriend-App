// Package skinpack builds a character skin from its text source. A skin folder (skins/<id>/) holds meta.json and
// pixel grids; Build turns it into the zip the apps install: a Lottie animation with a marker per action and a face
// layer per mood, a still PNG for every action and mood (widgets can't run Lottie), and a small head per mood for
// the Dynamic Island.
//
// Folder layout:
//
//	meta.json             id, name, fps, face_base, palette, actions (frames + still per vocabulary action),
//	                      motions (frames per Motions entry: app-only moves like walking, never picked by the AI)
//	body/<frame>.txt      32×32 grid: '.' transparent, palette keys, one '@' where the face's top-left goes
//	face/<mood>.txt       any size up to 32×32, '.' transparent
//	mini/<mood>.txt       16×16 head for the Dynamic Island
package skinpack

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image/color"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"befriend/pkg/utils/vocabulary"
)

const (
	Size     = 32 // body grids and stills are Size×Size pixels
	MiniSize = 16 // Dynamic Island heads are MiniSize×MiniSize
	maxFPS   = 30

	transparent = '.'
	faceOrigin  = '@' // top-left of the mood face on a body frame; the pixel itself is painted with face_base
)

// Motions are played by the apps themselves (the Mac walks the friend around); they get a marker after the actions
// and no stills, since widgets never move.
var Motions = []string{"walk"}

var (
	idPattern        = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)
	frameNamePattern = regexp.MustCompile(`^[a-z0-9_-]+(/[a-z0-9_-]+)?$`)
	hexColorPattern  = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
)

type meta struct {
	ID       string                `json:"id"`
	Name     string                `json:"name"`
	FPS      int                   `json:"fps"`
	FaceBase string                `json:"face_base"` // palette key painted under '@'
	Palette  map[string]string     `json:"palette"`   // one character → "#rrggbb"
	Actions  map[string]actionMeta `json:"actions"`
	Motions  map[string]motionMeta `json:"motions"`
}

type motionMeta struct {
	Frames []string `json:"frames"`
}

// clip is one marker's worth of timeline.
type clip struct {
	name   string
	frames []string
}

// timeline lists every marker in play order: the vocabulary actions, then the motions.
func (m *meta) timeline() []clip {
	var clips []clip
	for _, action := range vocabulary.Actions {
		clips = append(clips, clip{action, m.Actions[action].Frames})
	}
	for _, motion := range Motions {
		clips = append(clips, clip{motion, m.Motions[motion].Frames})
	}
	return clips
}

type actionMeta struct {
	Frames []string `json:"frames"` // grid names under body/, e.g. "wave/0"; repeat a name to hold it longer
	Still  int      `json:"still"`  // index into Frames drawn for widgets and Live Activities
}

// grid is a parsed pixel grid: a palette key or '.' per cell, row by row.
type grid struct {
	w, h         int
	cells        []byte
	faceX, faceY int // where the face goes; -1 when this frame hides it
}

type source struct {
	meta    meta
	palette map[byte]color.NRGBA
	bodies  map[string]*grid // by frame name, with '@' painted as face_base
	faces   map[string]*grid // by mood
	minis   map[string]*grid // by mood
}

func load(dir string) (*source, error) {
	m, err := readMeta(filepath.Join(dir, "meta.json"))
	if err != nil {
		return nil, err
	}
	palette, err := parsePalette(m.Palette)
	if err != nil {
		return nil, err
	}
	if _, ok := palette[firstByte(m.FaceBase)]; !ok || len(m.FaceBase) != 1 {
		return nil, fmt.Errorf("meta.json: face_base %q must be one palette key", m.FaceBase)
	}

	src := &source{meta: *m, palette: palette, bodies: map[string]*grid{}, faces: map[string]*grid{}, minis: map[string]*grid{}}
	if err := src.loadBodies(dir); err != nil {
		return nil, err
	}
	for _, mood := range vocabulary.Moods {
		if src.faces[mood], err = readGrid(filepath.Join(dir, "face", mood+".txt"), 0, 0, false, palette); err != nil {
			return nil, err
		}
		if src.minis[mood], err = readGrid(filepath.Join(dir, "mini", mood+".txt"), MiniSize, MiniSize, false, palette); err != nil {
			return nil, err
		}
	}
	return src, src.checkFacesFit()
}

func readMeta(path string) (*meta, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var m meta
	if err := decoder.Decode(&m); err != nil {
		return nil, fmt.Errorf("meta.json: %w", err)
	}
	switch {
	case !idPattern.MatchString(m.ID):
		return nil, fmt.Errorf("meta.json: id %q must be 1-40 of a-z, 0-9 and -", m.ID)
	case strings.TrimSpace(m.Name) == "" || utf8.RuneCountInString(m.Name) > 40:
		return nil, fmt.Errorf("meta.json: name must be 1-40 characters")
	case m.FPS < 1 || m.FPS > maxFPS:
		return nil, fmt.Errorf("meta.json: fps must be 1-%d", maxFPS)
	}
	for action := range m.Actions {
		if !vocabulary.IsAction(action) {
			return nil, fmt.Errorf("meta.json: %q is not a vocabulary v%d action", action, vocabulary.Version)
		}
	}
	for motion := range m.Motions {
		if !slices.Contains(Motions, motion) {
			return nil, fmt.Errorf("meta.json: %q is not a motion (%s)", motion, strings.Join(Motions, ", "))
		}
	}
	return &m, nil
}

func parsePalette(raw map[string]string) (map[byte]color.NRGBA, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("meta.json: palette is empty")
	}
	palette := map[byte]color.NRGBA{}
	for key, hex := range raw {
		if len(key) != 1 || key[0] <= ' ' || key[0] > '~' || key[0] == transparent || key[0] == faceOrigin {
			return nil, fmt.Errorf("meta.json: palette key %q must be one printable character other than '.' and '@'", key)
		}
		if !hexColorPattern.MatchString(hex) {
			return nil, fmt.Errorf("meta.json: palette %q = %q is not #rrggbb", key, hex)
		}
		v, _ := strconv.ParseUint(hex[1:], 16, 32)
		palette[key[0]] = color.NRGBA{R: uint8(v >> 16), G: uint8(v >> 8), B: uint8(v), A: 255}
	}
	return palette, nil
}

// loadBodies reads every frame the timeline uses, in play order; frames shared between clips load once.
func (s *source) loadBodies(dir string) error {
	for _, action := range vocabulary.Actions {
		a, ok := s.meta.Actions[action]
		switch {
		case !ok:
			return fmt.Errorf("meta.json: action %q is missing", action)
		case a.Still < 0 || a.Still >= max(len(a.Frames), 1):
			return fmt.Errorf("meta.json: action %q still %d is not a frame index", action, a.Still)
		}
	}
	for _, motion := range Motions {
		if _, ok := s.meta.Motions[motion]; !ok {
			return fmt.Errorf("meta.json: motion %q is missing", motion)
		}
	}
	for _, c := range s.meta.timeline() {
		if len(c.frames) == 0 {
			return fmt.Errorf("meta.json: %q has no frames", c.name)
		}
		for _, name := range c.frames {
			if s.bodies[name] != nil {
				continue
			}
			if !frameNamePattern.MatchString(name) {
				return fmt.Errorf("meta.json: frame name %q must look like wave/0", name)
			}
			g, err := readGrid(filepath.Join(dir, "body", name+".txt"), Size, Size, true, s.palette)
			if err != nil {
				return err
			}
			for i, cell := range g.cells {
				if cell == faceOrigin {
					g.cells[i] = s.meta.FaceBase[0]
				}
			}
			s.bodies[name] = g
		}
	}
	return nil
}

// checkFacesFit makes sure every face drawn at every frame's '@' stays on the canvas.
func (s *source) checkFacesFit() error {
	for name, body := range s.bodies {
		if body.faceX < 0 {
			continue
		}
		for mood, face := range s.faces {
			if body.faceX+face.w > Size || body.faceY+face.h > Size {
				return fmt.Errorf("face/%s.txt (%d×%d) runs off the canvas at body/%s.txt's '@' (%d,%d)",
					mood, face.w, face.h, name, body.faceX, body.faceY)
			}
		}
	}
	return nil
}

// readGrid parses a text grid. w and h of 0 accept any size up to the canvas; allowFaceOrigin permits one '@'.
func readGrid(path string, w, h int, allowFaceOrigin bool, palette map[byte]color.NRGBA) (*grid, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	name := filepath.Base(filepath.Dir(path)) + "/" + filepath.Base(path)
	text := strings.TrimRight(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n")

	g := &grid{faceX: -1, faceY: -1}
	for y, line := range strings.Split(text, "\n") {
		if y == 0 {
			g.w = len(line)
		}
		if len(line) != g.w {
			return nil, fmt.Errorf("%s: line %d is %d wide; line 1 is %d", name, y+1, len(line), g.w)
		}
		for x := 0; x < len(line); x++ {
			c := line[x]
			_, inPalette := palette[c]
			switch {
			case c == transparent || inPalette:
			case c == faceOrigin && allowFaceOrigin:
				if g.faceX >= 0 {
					return nil, fmt.Errorf("%s: more than one '@'", name)
				}
				g.faceX, g.faceY = x, y
			default:
				return nil, fmt.Errorf("%s: line %d column %d: %q is not in the palette", name, y+1, x+1, c)
			}
		}
		g.cells = append(g.cells, line...)
		g.h++
	}

	switch {
	case w > 0 && (g.w != w || g.h != h):
		return nil, fmt.Errorf("%s is %d×%d; want %d×%d", name, g.w, g.h, w, h)
	case g.w == 0 || g.w > Size || g.h > Size:
		return nil, fmt.Errorf("%s is %d×%d; want 1-%d on each side", name, g.w, g.h, Size)
	}
	return g, nil
}

func firstByte(s string) byte {
	if s == "" {
		return 0
	}
	return s[0]
}
