"""测试 MCP NewsNow 服务能否正常访问 https://newsnow.busiyi.world/

直接调用 server.py 中暴露的工具函数（fetch_news / fetch_multi_sources），
绕过 MCP 协议层，验证后端 API 与服务逻辑的连通性。
"""
import asyncio
import json
import time

from mcp_newsnow_server.server import news_mgr, BASE_URL, sources_list


def _truncate(text, n=200):
    if not isinstance(text, str):
        text = json.dumps(text, ensure_ascii=False)
    text = text.replace("\n", " ")
    return text if len(text) <= n else text[:n] + "..."


async def test_single_source(source):
    print(f"\n[单源测试] source={source}")
    t0 = time.perf_counter()
    result = await news_mgr.fetch_news(source)
    cost = (time.perf_counter() - t0) * 1000

    ok = False
    items_count = None
    if isinstance(result, str) and result.startswith("{"):
        try:
            data = json.loads(result)
            items_count = len(data.get("items", []))
            ok = items_count is not None and items_count > 0
        except Exception:
            ok = False

    status = "成功" if ok else "失败"
    print(f"  -> {status}  耗时={cost:.0f}ms  条数={items_count}")
    print(f"  -> 预览: {_truncate(result, 180)}")
    return ok


async def test_multi_sources(sources):
    print(f"\n[多源测试] sources={sources}")
    t0 = time.perf_counter()
    results = await news_mgr.fetch_multi_sources(sources)
    cost = (time.perf_counter() - t0) * 1000

    if not isinstance(results, dict):
        print(f"  -> 失败  返回非字典: {_truncate(results, 200)}")
        return False

    ok_all = True
    for src, data in results.items():
        if src == "warnings":
            print(f"  -> warnings: {data}")
            continue
        n = len(data.get("items", [])) if isinstance(data, dict) else None
        good = isinstance(n, int) and n > 0
        ok_all = ok_all and good
        print(f"  -> {src}: {'成功' if good else '失败'}, 条数={n}")
    print(f"  -> 总耗时={cost:.0f}ms")
    return ok_all


async def test_unknown_source():
    print("\n[异常测试] source=不存在的源_xxxxx")
    result = await news_mgr.fetch_news("不存在的源_xxxxx")
    is_dict_with_error = (
        isinstance(result, dict) and result.get("error") == "unknown_source"
    )
    print(f"  -> {'按预期返回错误提示' if is_dict_with_error else '行为异常'}")
    print(f"  -> 返回内容预览: {_truncate(result, 180)}")
    return is_dict_with_error


async def main():
    print("=" * 60)
    print("MCP NewsNow 服务连通性测试")
    print("=" * 60)
    print(f"BASE_URL = {BASE_URL}")
    print(f"内置可用源数量 = {len(sources_list)}")

    results = {
        "知乎(中文别名)": await test_single_source("知乎"),
        "github(英文别名)": await test_single_source("github"),
        "多源(知乎+B站+微博)": await test_multi_sources(["知乎", "b站", "微博"]),
        "未知源容错": await test_unknown_source(),
    }

    print("\n" + "=" * 60)
    print("测试汇总")
    print("=" * 60)
    for name, ok in results.items():
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")

    failed = [k for k, v in results.items() if not v]
    if failed:
        print(f"\n结论: 失败 {len(failed)}/{len(results)} -> {failed}")
        return 1
    print(f"\n结论: 全部通过 ({len(results)}/{len(results)}). MCP 服务可正常访问 newsnow API.")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
