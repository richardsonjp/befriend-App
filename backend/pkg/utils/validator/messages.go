package validator

import (
	"fmt"
	"strings"
)

var defaultMessages = map[string]string{
	"ERR_REQUIRED":   "{Field} tidak boleh kosong",
	"ERR_LEN":        "{Field} harus memiliki panjang {Length}",
	"ERR_EMAIL":      "{Field} bukan email yang valid",
	"ERR_MAX":        "{Field} tidak boleh lebih dari {Length}",
	"ERR_MIN":        "{Field} tidak boleh kurang dari {Length}",
	"ERR_NUMERIC":    "{Field} harus berupa angka",
	"ERR_URL":        "{Field} bukan URL yang valid",
	"ERR_WHITELIST":  "IP ({Field}) tidak valid",
	"ERR_ALPHASPACE": "Value ({Field}) tidak valid, hanya boleh mengandung karakter alphabet dan spasi",
	"ERR_VALUE":      "Value ({Field}) tidak valid",
	"ERR_DATE":       "Tanggal ({Field}) tidak valid.",
	"ERR_PASSWORD":   "Password tidak valid. Minimum 8 karakter dan maksimum 64 karakter (alphanumeric)",
}

func translate(key string, data map[string]interface{}) (string, error) {
	msg, ok := defaultMessages[key]
	if !ok {
		return key, nil
	}

	for k, v := range data {
		placeholder := fmt.Sprintf("{%s}", k)
		val := fmt.Sprintf("%v", v)
		msg = strings.ReplaceAll(msg, placeholder, val)
	}

	return msg, nil
}
