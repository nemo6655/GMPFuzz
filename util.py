import subprocess
from typing import Union

def get_config(key: str) -> Union[str, list[str]]:
    """Get a configuration value from the YAML config via elmconfig.py."""
    cmd = [
        './elmconfig.py',
        'get',
        key
    ]
    p = subprocess.run(cmd, capture_output=True, check=True)
    r = p.stdout.decode().strip()
    if r.count(' ') > 0:
        return r.split(' ')
    else:
        return r

def get_state_sequence(content: list[str]) -> list[str]:
    """
    Extracts the state sequence from the coverage file content.
    The content is expected to be a list of strings (lines from the file).
    The first line might contain state info in the format: state:0-200-201-202::::
    """
    if not content:
        return []
    
    first_line = content[0]
    if first_line.startswith("state:") and "::::" in first_line:
        try:
            state_part = first_line.split("state:", 1)[1].split("::::", 1)[0]
            states = [s for s in state_part.split('-') if s.isdigit()]
            return states
        except IndexError:
            return []
    return []
