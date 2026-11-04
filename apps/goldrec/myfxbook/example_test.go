package myfxbook_test

import (
	"fmt"

	"github.com/condrove10/gomql5/apps/goldrec/myfxbook"
)

// Parse a get-community-outlook.json body and normalise XAUUSD. Supplied
// values keep the vendor's exact text; derived values are ours and named so;
// anything odd becomes a quality flag instead of a silent fix.
func ExampleNormalize() {
	body := []byte(`{"error":false,"message":"","symbols":[{"name":"XAUUSD",
	  "longPercentage":62,"shortPercentage":38,"longVolume":836.10,"shortVolume":512.34,
	  "longPositions":7311,"shortPositions":4180,"totalPositions":11500,
	  "avgLongPrice":4031.55,"avgShortPrice":3990.12}]}`) // synthetic

	resp, err := myfxbook.Parse(body)
	if err != nil || resp.Error {
		fmt.Println("vendor error:", err, resp.Message)
		return
	}
	n := myfxbook.Normalize(resp.Find("XAUUSD")[0])
	fmt.Println("long lots (as supplied):", *n.Supplied.LongVolume)
	fmt.Printf("long share by lots: %.4f, by positions: %.4f\n", *n.Derived.LongVolumeShare, *n.Derived.LongCountShare)
	fmt.Println("quality:", n.Quality, "quarantined:", n.Quarantined)
	// Output:
	// long lots (as supplied): 836.10
	// long share by lots: 0.6200, by positions: 0.6362
	// quality: [total_mismatch] quarantined: false
}
