package skinpack

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"time"

	"befriend/pkg/utils/vocabulary"
)

const (
	Format      = 1       // manifest format the apps understand
	MaxZipBytes = 2 << 20 // the apps refuse bigger downloads
)

// zipTime is every entry's modification time, so the same source always packs to the same bytes.
var zipTime = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// Package is a built skin.
type Package struct {
	ID     string
	Name   string
	Zip    []byte
	SHA256 string // hex digest of Zip
}

// Manifest is manifest.json inside the zip.
type Manifest struct {
	Format            int    `json:"format"`
	ID                string `json:"id"`
	Name              string `json:"name"`
	VocabularyVersion int    `json:"vocabulary_version"`
	Size              int    `json:"size"`
	MiniSize          int    `json:"mini_size"`
	FPS               int    `json:"fps"`
}

type entry struct {
	name   string
	data   []byte
	stored bool // already compressed (PNG)
}

// Build validates a skin folder and packs manifest.json, skin.json (Lottie), mini/<mood>.png and
// stills/<action>/<mood>.png, in that order.
func Build(dir string) (*Package, error) {
	src, err := load(dir)
	if err != nil {
		return nil, err
	}
	entries, err := src.entries()
	if err != nil {
		return nil, err
	}
	data, err := pack(entries)
	if err != nil {
		return nil, err
	}
	if len(data) > MaxZipBytes {
		return nil, fmt.Errorf("%s packs to %d bytes; the apps accept at most %d", src.meta.ID, len(data), MaxZipBytes)
	}
	sum := sha256.Sum256(data)
	return &Package{ID: src.meta.ID, Name: src.meta.Name, Zip: data, SHA256: hex.EncodeToString(sum[:])}, nil
}

func (s *source) entries() ([]entry, error) {
	manifest, err := json.Marshal(Manifest{
		Format: Format, ID: s.meta.ID, Name: s.meta.Name, VocabularyVersion: vocabulary.Version,
		Size: Size, MiniSize: MiniSize, FPS: s.meta.FPS,
	})
	if err != nil {
		return nil, err
	}
	animation, err := json.Marshal(s.lottie())
	if err != nil {
		return nil, err
	}
	entries := []entry{{name: "manifest.json", data: manifest}, {name: "skin.json", data: animation}}

	for _, mood := range vocabulary.Moods {
		img, err := s.pixelPNG(s.minis[mood], nil)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry{name: "mini/" + mood + ".png", data: img, stored: true})
	}
	for _, action := range vocabulary.Actions {
		a := s.meta.Actions[action]
		body := s.bodies[a.Frames[a.Still]]
		for _, mood := range vocabulary.Moods {
			img, err := s.pixelPNG(body, s.faces[mood])
			if err != nil {
				return nil, err
			}
			entries = append(entries, entry{name: "stills/" + action + "/" + mood + ".png", data: img, stored: true})
		}
	}
	return entries, nil
}

// pixelPNG draws a grid at 1 pixel per cell, with face drawn at the grid's '@' when the frame shows one.
func (s *source) pixelPNG(g *grid, face *grid) ([]byte, error) {
	img := image.NewNRGBA(image.Rect(0, 0, g.w, g.h))
	s.paint(img, g, 0, 0)
	if face != nil && g.faceX >= 0 {
		s.paint(img, face, g.faceX, g.faceY)
	}
	var buf bytes.Buffer
	err := (&png.Encoder{CompressionLevel: png.BestCompression}).Encode(&buf, img)
	return buf.Bytes(), err
}

func (s *source) paint(img *image.NRGBA, g *grid, left, top int) {
	for y := 0; y < g.h; y++ {
		for x := 0; x < g.w; x++ {
			if c := g.cells[y*g.w+x]; c != transparent {
				img.SetNRGBA(left+x, top+y, s.palette[c])
			}
		}
	}
}

func pack(entries []entry) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, e := range entries {
		method := zip.Deflate
		if e.stored {
			method = zip.Store
		}
		w, err := zw.CreateHeader(&zip.FileHeader{Name: e.name, Method: method, Modified: zipTime})
		if err != nil {
			return nil, err
		}
		if _, err := w.Write(e.data); err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
