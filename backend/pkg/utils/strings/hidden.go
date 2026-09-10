package strings

import "unicode"

const zeroWidthJoiner = '\u200d'

// IsHiddenRune reports characters that render invisibly or reorder surrounding text: control
// characters other than whitespace, and Unicode format characters (zero-width spaces, bidi overrides,
// byte-order marks) except the zero-width joiner that emoji sequences like 👩\u200d💻 need. Text that ends up
// in an LLM prompt or on screen shouldn't carry them.
func IsHiddenRune(r rune) bool {
	return (unicode.IsControl(r) && !unicode.IsSpace(r)) || (unicode.Is(unicode.Cf, r) && r != zeroWidthJoiner)
}
