package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestResultBlocks(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want []string
	}{
		{"string", `"hello"`, []string{"hello"}},
		{"stringified mcp array", `"[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]"`, []string{"a", "b"}},
		{"stringified call tool result", `"{\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}"`, []string{"a"}},
		{"string that is plain JSON stays one block", `"{\"a\":1}"`, []string{`{"a":1}`}},
		{"mcp array", `[{"type":"text","text":"echo: hello"}]`, []string{"echo: hello"}},
		{"mcp array keeps order and extra keys", `[{"type":"text","text":"a","annotations":{}},{"type":"text","text":"b"}]`, []string{"a", "b"}},
		{"call tool result object", `{"content":[{"type":"text","text":"foo"},{"type":"text","text":"bar"}],"isError":false}`, []string{"foo", "bar"}},
		{"mixed text and image skips image", `[{"type":"text","text":"a"},{"type":"image","data":"AAAA"},{"type":"text","text":"b"}]`, []string{"a", "b"}},
		{"only images falls back", `[{"type":"image","data":"AAAA"}]`, []string{`[{"type":"image","data":"AAAA"}]`}},
		{"other object falls back compact", "{\n  \"commits\": [\"a\"]\n}", []string{`{"commits":["a"]}`}},
		{"array without block types falls back", `[1,2]`, []string{`[1,2]`}},
		{"empty raw", ``, nil},
		{"null", `null`, nil},
		{"blank raw", `   `, nil},
		{"invalid JSON kept as is", `{"a":`, []string{`{"a":`}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resultBlocks(json.RawMessage(tt.raw))
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("resultBlocks(%s) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

func TestClipIsUTF8Safe(t *testing.T) {
	tests := []struct {
		name string
		in   string
		n    int
		want string
	}{
		{"fits", "abc", 3, "abc"},
		{"ascii cut", "abcdef", 4, "abcd"},
		{"cut inside rune backs off", "aéb", 2, "a"},
		{"cut on rune boundary", "aéb", 3, "aé"},
		{"four byte rune", "😀😀", 5, "😀"},
		{"zero", "abc", 0, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := clip(tt.in, tt.n); got != tt.want {
				t.Fatalf("clip(%q, %d) = %q, want %q", tt.in, tt.n, got, tt.want)
			}
		})
	}
}

func payloadTexts(t *testing.T, captured map[string]any) []string {
	t.Helper()
	content := captured["payload"].(map[string]any)["result"].(map[string]any)["content"].([]any)
	texts := make([]string, 0, len(content))
	for _, c := range content {
		block := c.(map[string]any)
		if block["type"] != "text" {
			t.Fatalf("expected text block, got %v", block)
		}
		texts = append(texts, block["text"].(string))
	}
	return texts
}

func textBlock(s string) map[string]any { return map[string]any{"type": "text", "text": s} }

func TestPostMCPToolUsePayloadBlocks(t *testing.T) {
	tests := []struct {
		name     string
		result   any
		maxBytes int
		want     []string
		skipped  bool
	}{
		{"string is one block", "foo", 0, []string{"foo"}, false},
		{"multi block", []any{textBlock("a"), textBlock("b")}, 0, []string{"a", "b"}, false},
		{"call tool result object", map[string]any{"content": []any{textBlock("x"), textBlock("y")}}, 0, []string{"x", "y"}, false},
		{"budget spans blocks and truncates the last", []any{textBlock("aaaa"), textBlock("bbbb"), textBlock("cccc")}, 6, []string{"aaaa", "bb"}, false},
		{"budget exhausted drops later blocks", []any{textBlock("aaaa"), textBlock("bbbb")}, 4, []string{"aaaa"}, false},
		{"clip does not split a rune", []any{textBlock("ééé")}, 3, []string{"é"}, false},
		{"other object is one compact block", map[string]any{"query": "q", "total": 1}, 0, []string{`{"query":"q","total":1}`}, false},
		{"blank blocks skip the evaluate", []any{textBlock("  "), textBlock("")}, 0, nil, true},
		{"empty string skips the evaluate", "", 0, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv, captured := stubGuard(t, EvaluateResponse{Status: "allow"})
			cfg := testConfig(srv.URL)
			if tt.maxBytes > 0 {
				cfg.MaxContentBytes = tt.maxBytes
			}
			_ = invokeHook(t, cfg, event("post_mcp_tool_use", map[string]any{
				"mcp_server_name": "echo",
				"mcp_tool_name":   "echo",
				"mcp_result":      tt.result,
			}))
			if tt.skipped {
				if len(*captured) != 0 {
					t.Fatalf("expected no evaluate, got %v", *captured)
				}
				return
			}
			if (*captured)["direction"] != "output" || (*captured)["protocol"] != "mcp" {
				t.Fatalf("unexpected envelope: %v", *captured)
			}
			got := payloadTexts(t, *captured)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("blocks = %q, want %q", got, tt.want)
			}
			if total := len(strings.Join(got, "")); tt.maxBytes > 0 && total > tt.maxBytes {
				t.Fatalf("sent %d bytes, budget %d", total, tt.maxBytes)
			}
			if attr(t, captured, "tool")["name"] != "echo" {
				t.Fatalf("attributes.tool.name changed: %v", (*captured)["attributes"])
			}
		})
	}
}

func TestDevinPostToolUseMCPContentBlocks(t *testing.T) {
	tests := []struct {
		name     string
		response any
		want     []string
	}{
		{"content array", []any{textBlock("a"), textBlock("b")}, []string{"a", "b"}},
		{"content object", map[string]any{"content": []any{textBlock("x"), textBlock("y")}}, []string{"x", "y"}},
		{"output stays one block", map[string]any{"success": true, "output": "done"}, []string{"done"}},
		{"bare string", "plain", []string{"plain"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv, captured := stubGuard(t, EvaluateResponse{Status: "allow"})
			_ = invokeHook(t, testConfig(srv.URL), devinEvent(devinPostToolUse, map[string]any{
				"tool_name":     "mcp__notes__fetch",
				"tool_input":    map[string]any{"id": 1},
				"tool_response": tt.response,
			}))
			if got := payloadTexts(t, *captured); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("blocks = %q, want %q", got, tt.want)
			}
		})
	}
}
