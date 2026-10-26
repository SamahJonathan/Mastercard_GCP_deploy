import importlib.util
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("run_queries", ROOT / "scripts" / "run_queries.py")
run_queries = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(run_queries)


def test_every_query_renders_to_fully_qualified_tables():
    files = run_queries.queries([])
    assert len(files) == 12
    for f in files:
        sql = run_queries.render(f.read_text(encoding="utf-8"), "proj-x", "paylake_dev")
        assert "${" not in sql, f.name
        # Toda tabla va calificada con proyecto y dataset de una capa
        for ref in re.findall(r"`([^`]+)`", sql):
            project, dataset, _ = ref.split(".")
            assert project == "proj-x" and dataset in {"paylake_dev_bronze", "paylake_dev_silver", "paylake_dev_gold"}, ref


def test_queries_use_googlesql_syntax():
    for f in run_queries.queries([]):
        sql = f.read_text(encoding="utf-8").lower()
        # Funciones de otros dialectos que BigQuery no acepta
        for foreign in ("approx_percentile", "count_if(", "date_format(", "filter (where", "interval '"):
            assert foreign not in sql, f"{f.name}: {foreign}"


def test_only_filters_by_number():
    assert [f.name[:2] for f in run_queries.queries(["03", "10"])] == ["03", "10"]
