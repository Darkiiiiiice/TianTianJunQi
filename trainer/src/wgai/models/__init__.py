"""策略/价值网络：CNN trunk + policy/value 双头（M3 落地）。

网络结构由 model.json 描述，Python 导出、MLX Swift 按同一份配置重建；
固定输入做输出一致性测试（容差 1e-4）。
"""
