// Command trustguard-windsurf bridges Windsurf (Devin Desktop) Cascade hooks
// with the TrustGuard data-plane API. Cascade invokes it per hook event with
// the event JSON on stdin; the binary maps the event to POST /v1/evaluate and
// answers in the Cascade hook contract, which is the exit code:
//
//	0  the action proceeds
//	2  a pre-hook blocks the action; the reason on stderr is shown to the agent
//
// Any other code lets the action proceed, so an unexpected failure of this
// binary never locks the developer out.
//
// Subcommands:
//
//	hook     read one hook event from stdin, evaluate it, answer (default)
//	version  print the integration version
package main

import (
	"fmt"
	"os"
)

const integrationVersion = "0.1.0"

func main() {
	cmd := "hook"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}

	switch cmd {
	case "hook":
		code, err := runHook(os.Stdin, os.Stdout, os.Stderr, loadConfig())
		if err != nil {
			fmt.Fprintf(os.Stderr, "trustguard-windsurf hook: %v\n", err)
			os.Exit(1)
		}
		os.Exit(code)
	case "version":
		fmt.Println(integrationVersion)
	case "help", "-h", "--help":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n", cmd)
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Print(`trustguard-windsurf — TrustGuard integration for Windsurf Cascade hooks

Usage:
  trustguard-windsurf [hook]         evaluate one hook event (stdin JSON → exit code)
  trustguard-windsurf version        print version

Runtime configuration (env wins over ~/.trustguard/windsurf.json, except when
MDM managed mode locks api_key/data_url/fail_mode):
  TRUSTGUARD_DATA_URL          data-plane base URL   (default http://localhost:8081)
  TRUSTGUARD_API_KEY           org Windsurf collector API key (tgk_…)
  TRUSTGUARD_FAIL_MODE         open|closed on guard errors (default open)
  TRUSTGUARD_TIMEOUT_MS        evaluate timeout in ms      (default 5000)
  TRUSTGUARD_WINDSURF_CONFIG   alternative config file path
`)
}
