"""模型导出：safetensors + model.json + manifest.json（M3 落地）。

产物写入 models/<version>/；Swift 端按 manifest 加载，manifest 不匹配标 stale。
"""
