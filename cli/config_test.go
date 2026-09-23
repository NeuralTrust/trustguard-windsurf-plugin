package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnvFillsConfig(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("TRUSTGUARD_WINDSURF_SYSTEM_CONFIG", filepath.Join(dir, "missing-system.json"))
	t.Setenv("TRUSTGUARD_WINDSURF_CONFIG", filepath.Join(dir, "missing-user.json"))
	t.Setenv("TRUSTGUARD_API_KEY", "tgk_env")
	t.Setenv("TRUSTGUARD_DATA_URL", "https://env.example")
	t.Setenv("TRUSTGUARD_FAIL_MODE", "closed")
	t.Setenv("TRUSTGUARD_TIMEOUT_MS", "750")

	cfg := loadConfig()
	if cfg.APIKey != "tgk_env" || cfg.DataURL != "https://env.example" || cfg.FailMode != "closed" || cfg.TimeoutMS != 750 {
		t.Fatalf("env not applied: %+v", cfg)
	}
	if cfg.AskAction != "deny" || cfg.TransformAction != "deny" || cfg.MaxContentBytes != defaultMaxContentBytes {
		t.Fatalf("defaults not applied: %+v", cfg)
	}
}

func TestManagedModeLocksKeyFields(t *testing.T) {
	dir := t.TempDir()
	system := filepath.Join(dir, "system.json")
	user := filepath.Join(dir, "user.json")
	if err := os.WriteFile(system, []byte(`{"api_key":"tgk_managed","data_url":"https://managed.example","fail_mode":"closed"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(user, []byte(`{"api_key":"tgk_user","data_url":"https://user.example","fail_mode":"open","timeout_ms":1234,"ask_action":"allow"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Setenv("TRUSTGUARD_WINDSURF_SYSTEM_CONFIG", system)
	t.Setenv("TRUSTGUARD_WINDSURF_CONFIG", user)
	t.Setenv("TRUSTGUARD_API_KEY", "tgk_env")
	t.Setenv("TRUSTGUARD_DATA_URL", "https://env.example")
	t.Setenv("TRUSTGUARD_FAIL_MODE", "open")

	cfg := loadConfig()
	if !cfg.managed {
		t.Fatal("expected managed mode")
	}
	if cfg.APIKey != "tgk_managed" || cfg.DataURL != "https://managed.example" || cfg.FailMode != "closed" {
		t.Fatalf("locked fields overridden: %+v", cfg)
	}
	if cfg.TimeoutMS != 1234 || cfg.AskAction != "allow" {
		t.Fatalf("soft prefs not applied: %+v", cfg)
	}
}
