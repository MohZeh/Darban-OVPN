package caindex

import "time"

// ExpiryEpoch reads an expiry of index.txt, an ASN.1 UTCTime (YYMMDDHHMMSSZ, years before 50 in the 2000s) or
// GeneralizedTime (YYYYMMDDHHMMSSZ), as seconds since 1970. A date that does not exist, such as February 30, is
// not read, as GNU date does not read it.
func ExpiryEpoch(value string) (int64, bool) {
	var year, rest string
	switch {
	case len(value) == 13 && value[12] == 'Z' && digits(value[:12]):
		year, rest = value[:2], value[2:12]
		if atoi(year) < 50 {
			year = "20" + year
		} else {
			year = "19" + year
		}
	case len(value) == 15 && value[14] == 'Z' && digits(value[:14]):
		year, rest = value[:4], value[4:14]
	default:
		return 0, false
	}
	y, mo, d := atoi(year), atoi(rest[0:2]), atoi(rest[2:4])
	h, mi, s := atoi(rest[4:6]), atoi(rest[6:8]), atoi(rest[8:10])
	t := time.Date(y, time.Month(mo), d, h, mi, s, 0, time.UTC)
	if t.Year() != y || int(t.Month()) != mo || t.Day() != d || t.Hour() != h || t.Minute() != mi || t.Second() != s {
		return 0, false
	}
	return t.Unix(), true
}

// Day is an epoch as the manager shows a date: 2029-02-05, in UTC.
func Day(epoch int64) string { return time.Unix(epoch, 0).UTC().Format("2006-01-02") }

func digits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func atoi(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n
}
