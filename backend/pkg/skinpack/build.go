package skinpack

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"time"
)

const (
	Format      = 2       // manifest format the apps understand
	MaxZipBytes = 2 << 20 // the apps refuse bigger downloads
)

// zipTime is every entry's modification time, so the same source always packs to the same bytes.
var zipTime = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// Package is a built skin.
type Package struct {
	ID    string
	Name  string
	Clips []Clip
	Moods []string
	// Preview is idle's first frame, shown in the shop.
	Preview []byte
	Zip     []byte
	SHA256  string // hex digest of Zip
}

// Clip is one playable animation: "wave" plays in any mood, "wave/grumpy" only in that mood.
type Clip struct {
	Name   string `json:"name"`
	Frames int    `json:"frames"`
}

// Manifest is manifest.json inside the zip. Clips and moods are a list, not a map: the apps' snake_case key
// decoding would rewrite names like walk_left.
type Manifest struct {
	Format   int      `json:"format"`
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Size     int      `json:"size"`
	MiniSize int      `json:"mini_size"`
	FPS      int      `json:"fps"`
	Clips    []Clip   `json:"clips"`
	Moods    []string `json:"moods"`
}

// Build validates a skin folder and packs manifest.json, frames/<clip>/<n>.png and mini/<name>.png.
func Build(dir string) (*Package, error) {
	src, err := load(dir)
	if err != nil {
		return nil, err
	}
	var clips []Clip
	for _, name := range slices.Sorted(maps.Keys(src.clips)) {
		clips = append(clips, Clip{Name: name, Frames: len(src.clips[name])})
	}
	manifest, err := json.Marshal(Manifest{
		Format: Format, ID: src.id, Name: src.meta.Name, Size: Size, MiniSize: MiniSize, FPS: src.meta.FPS,
		Clips: clips, Moods: append([]string{}, src.moods...), // [] rather than null for a mood-less skin
	})
	if err != nil {
		return nil, err
	}

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	write := func(name string, data []byte, method uint16) error {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: method, Modified: zipTime})
		if err == nil {
			_, err = w.Write(data)
		}
		return err
	}
	if err := write("manifest.json", manifest, zip.Deflate); err != nil {
		return nil, err
	}
	for _, clip := range clips {
		for i, frame := range src.clips[clip.Name] {
			if err := write("frames/"+clip.Name+"/"+strconv.Itoa(i)+".png", frame, zip.Store); err != nil {
				return nil, err
			}
		}
	}
	for _, name := range slices.Sorted(maps.Keys(src.minis)) {
		if err := write("mini/"+name+".png", src.minis[name], zip.Store); err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}

	data := buf.Bytes()
	if len(data) > MaxZipBytes {
		return nil, fmt.Errorf("%s packs to %d bytes; the apps accept at most %d", src.id, len(data), MaxZipBytes)
	}
	sum := sha256.Sum256(data)
	return &Package{ID: src.id, Name: src.meta.Name, Clips: clips, Moods: src.moods, Preview: src.clips["idle"][0],
		Zip: data, SHA256: hex.EncodeToString(sum[:])}, nil
}
