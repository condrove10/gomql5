// Command basic waits for a GoBridge EA, prints account and market data, and
// streams ticks. With -trade it opens and closes a minimum-volume position:
// use a DEMO account.
//
//	GOBRIDGE_TOKEN=secret go run ./examples/basic -listen :7788 -symbol EURUSD
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"time"

	"github.com/condrove10/gomql5/mt5"
)

func main() {
	listen := flag.String("listen", ":7788", "address the EA connects to")
	symbol := flag.String("symbol", "EURUSD", "symbol to query")
	trade := flag.Bool("trade", false, "open and close a min-volume position (DEMO only)")
	ticks := flag.Int("ticks", 10, "ticks to stream before exiting (0 = until Ctrl-C)")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	srv, err := mt5.Listen(*listen, mt5.Config{Token: os.Getenv("GOBRIDGE_TOKEN")})
	if err != nil {
		log.Fatal(err)
	}
	defer srv.Close()
	log.Printf("waiting for GoBridge EA on %s", srv.Addr())

	term, err := srv.Accept(ctx)
	if err != nil {
		log.Fatal(err)
	}
	defer term.Close()
	h := term.Hello()
	log.Printf("EA %s connected: login=%d server=%q build=%d", h.EAVersion, h.Login, h.Server, h.Build)

	ti, err := term.TerminalInfo(ctx)
	check(err)
	fmt.Printf("terminal: %s build %d connected=%v algo-trading=%v\n", ti.Name, ti.Build, ti.Connected, ti.TradeAllowed && ti.EATradeAllowed)

	ai, err := term.AccountInfo(ctx)
	check(err)
	fmt.Printf("account %d (%s) %s balance=%.2f equity=%.2f leverage=1:%d\n",
		ai.Login, ai.Server, ai.Currency, ai.Balance, ai.Equity, ai.Leverage)

	si, err := term.SymbolInfo(ctx, *symbol)
	check(err)
	fmt.Printf("%s: digits=%d bid=%v ask=%v vol min/step=%v/%v\n", si.Name, si.Digits, si.Bid, si.Ask, si.VolumeMin, si.VolumeStep)

	rates, err := term.CopyRatesFromPos(ctx, *symbol, mt5.TimeframeH1, 0, 5)
	check(err)
	for _, r := range rates {
		fmt.Printf("  %s O=%v H=%v L=%v C=%v\n", mt5.ServerTime(r.Time).Format("2006-01-02 15:04"), r.Open, r.High, r.Low, r.Close)
	}

	if *trade {
		demoTrade(ctx, term, ai, si)
	}

	check(term.SubscribeTicks(ctx, *symbol))
	for n := 0; *ticks == 0 || n < *ticks; n++ {
		select {
		case tk, ok := <-term.Ticks():
			if !ok {
				log.Fatalf("terminal closed: %v", term.Err())
			}
			fmt.Printf("tick %s %s bid=%v ask=%v\n", tk.Symbol, mt5.ServerTimeMsc(tk.TimeMsc).Format("15:04:05.000"), tk.Bid, tk.Ask)
		case <-ctx.Done():
			return
		}
	}
}

func demoTrade(ctx context.Context, term *mt5.Terminal, ai mt5.AccountInfo, si mt5.SymbolInfo) {
	if ai.TradeMode != mt5.AccountTradeModeDemo {
		log.Fatal("-trade refused: account is not a demo account")
	}
	req := mt5.TradeRequest{
		Action: mt5.TradeActionDeal, Symbol: si.Name, Volume: si.VolumeMin,
		Type: mt5.OrderTypeBuy, TypeFilling: fillingFor(si), Deviation: 20,
		Magic: 424242, Comment: "gomql5 example",
	}
	chk, err := term.OrderCheck(ctx, req)
	check(err)
	fmt.Printf("order_check: retcode=%d %s margin=%.2f\n", chk.Retcode, chk.Comment, chk.Margin)

	res, err := term.OrderSend(ctx, req)
	check(err)
	fmt.Printf("buy: retcode=%d order=%d deal=%d price=%v %s\n", res.Retcode, res.Order, res.Deal, res.Price, res.Comment)
	if res.Retcode != mt5.TradeRetcodeDone {
		return
	}
	time.Sleep(time.Second)
	pos, err := term.PositionsGet(ctx, mt5.Filter{Symbol: si.Name})
	check(err)
	for _, p := range pos {
		if p.Magic != 424242 {
			continue
		}
		cl := req
		cl.Type, cl.Position, cl.Volume = mt5.OrderTypeSell, p.Ticket, p.Volume
		r, err := term.OrderSend(ctx, cl)
		check(err)
		fmt.Printf("close #%d: retcode=%d %s\n", p.Ticket, r.Retcode, r.Comment)
	}
}

// fillingFor picks a filling mode the symbol allows (SYMBOL_FILLING_MODE bit flags).
func fillingFor(si mt5.SymbolInfo) mt5.OrderFilling {
	switch {
	case si.FillingMode&1 != 0:
		return mt5.OrderFillingFok
	case si.FillingMode&2 != 0:
		return mt5.OrderFillingIoc
	default:
		return mt5.OrderFillingReturn
	}
}

func check(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
