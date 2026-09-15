from __future__ import annotations

from pathlib import Path

import pytest

from paid_media_agent.config import AccountRegistry, ModelConfig, Settings
from paid_media_agent.middleware.tool_selection import (
    SelectionStrategy,
    build_selection_middleware,
    capabilities_for,
    plan_selection,
)


def test_model_config_requires_provider_prefix() -> None:
    with pytest.raises(ValueError):
        ModelConfig.parse("claude-sonnet-4-6")
    config = ModelConfig.parse("Anthropic:claude-sonnet-4-6", base_url="https://proxy.example/v1")
    assert config.provider == "anthropic"
    assert config.spec == "anthropic:claude-sonnet-4-6"
    assert str(config.base_url).startswith("https://proxy.example")
    assert ModelConfig.parse("anthropic/claude-sonnet-4-6").spec == (
        "langsmith:anthropic/claude-sonnet-4-6"
    )


def test_registry_is_exact_not_substring() -> None:
    assert capabilities_for(ModelConfig.parse("anthropic:claude-sonnet-4-6")).native_tool_search
    unknown = capabilities_for(ModelConfig.parse("anthropic:claude-sonnet-4-6-experimental"))
    assert not unknown.native_tool_search and not unknown.verified
    assert not capabilities_for(ModelConfig.parse("openai:gpt-4o")).native_tool_search


def test_plan_selection_paths() -> None:
    native = plan_selection(ModelConfig.parse("openai:gpt-5.5"), max_tools=6)
    assert native.strategy is SelectionStrategy.PROVIDER_NATIVE
    proxied = plan_selection(
        ModelConfig.parse("openai:gpt-5.5", base_url="https://proxy.example/v1"), max_tools=6
    )
    assert proxied.strategy is SelectionStrategy.PORTABLE_SELECTOR
    google = plan_selection(ModelConfig.parse("google_genai:gemini-3-flash"), max_tools=6)
    assert google.strategy is SelectionStrategy.PORTABLE_SELECTOR
    scripted = plan_selection(ModelConfig.parse("scripted:demo"), max_tools=6)
    assert scripted.strategy is SelectionStrategy.NONE
    assert (
        build_selection_middleware(scripted, searchable_tool_names=["a"], always_include=["b"])
        == ()
    )


def test_settings_secret_helpers_never_expose_values(tmp_path: Path) -> None:
    settings = Settings(
        _env_file=None,  # type: ignore[call-arg]
        paid_media_api_tokens="tok-abc:alice,tok-def:bob,malformed",
        paid_media_approver_ids="alice, bob",
        pipeboard_api_token="",
        paid_media_approval_signing_key="signing-secret-value",
    )
    assert settings.api_token_map() == {"tok-abc": "alice", "tok-def": "bob"}
    assert settings.approver_refs() == frozenset({"alice", "bob"})
    assert settings.pipeboard_api_token is None
    assert "tok-abc" not in repr(settings) and "signing-secret-value" not in repr(settings)


def test_account_registry_from_toml(project_root: Path) -> None:
    registry = AccountRegistry.from_toml(project_root / "config" / "accounts.example.toml")
    assert registry.aliases() == ("demo-google", "demo-meta", "demo-reddit")
    binding = registry.resolve("demo-google")
    assert binding is not None and binding.platform.value == "google_ads"
    assert registry.resolve("unknown") is None
    assert "fixture-google-0001" in registry.provider_ids()


def test_vertex_providers_use_adc_and_portable_selection(monkeypatch: pytest.MonkeyPatch) -> None:
    from paid_media_agent.admin.envfile import key_spec
    from paid_media_agent.admin.model_presets import PROVIDER_IMPORT_MODULES, model_key_env
    from paid_media_agent.assembly import VERTEX_PROVIDERS, resolve_model
    from paid_media_agent.middleware.tool_selection import PROVIDER_DISTRIBUTIONS

    captured: dict[str, object] = {}

    def fake_init(spec: str, **kwargs: object) -> object:
        captured["spec"] = spec
        captured.update(kwargs)
        return object()

    monkeypatch.setattr("langchain.chat_models.init_chat_model", fake_init)
    vertex = ModelConfig.parse("google_vertexai:gemini-3.8-flash")
    assert capabilities_for(vertex).verified and not capabilities_for(vertex).native_tool_search
    assert plan_selection(vertex, max_tools=6).strategy is SelectionStrategy.PORTABLE_SELECTOR
    resolve_model(vertex, vertex_project="demo-project", vertex_location="europe-west1")
    assert captured["spec"] == "google_vertexai:gemini-3.8-flash"
    assert captured["project"] == "demo-project" and captured["location"] == "europe-west1"
    assert "api_key" not in captured, "Vertex authenticates with ADC, never a stored key"

    captured.clear()
    resolve_model(ModelConfig.parse("anthropic:claude-sonnet-4-6"), vertex_project="demo-project")
    assert "project" not in captured, "project and location apply to Vertex providers only"

    for provider in VERTEX_PROVIDERS:
        assert PROVIDER_DISTRIBUTIONS[provider] == "langchain-google-vertexai"
        assert PROVIDER_IMPORT_MODULES[provider] == "langchain_google_vertexai"
    assert key_spec("GOOGLE_CLOUD_PROJECT") is not None and key_spec("GOOGLE_CLOUD_LOCATION")

    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "env-project")
    settings = Settings(_env_file=None, paid_media_model="google_vertexai:gemini-3-flash")  # type: ignore[call-arg]
    assert settings.google_cloud_project == "env-project"
    assert model_key_env(settings) is None, "no API key variable is required for Vertex"
