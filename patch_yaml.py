import yaml
with open('preset/flashmq/config_ablation.yaml', 'r') as f:
    data = yaml.safe_load(f)
data['ase']['T_min'] = 3600
data['ase']['T_max'] = 21600
data['ase']['T_default'] = 3600
data['run']['max_generations'] = 3
with open('preset/flashmq/config_ablation.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False)
