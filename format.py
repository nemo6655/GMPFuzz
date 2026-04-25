import re
from pathlib import Path

content = Path('test.tex').read_text()
content = re.sub(r'\\subsection\{RQ1: Effectiveness of GMPFuzz\}\n*(?=\\subsection\{RQ2)', r'\\subsection{RQ1: Effectiveness of GMPFuzz}\n\n', content)
# It's already replaced successfully so this is just to double check there's no dangling \subsection{RQ1...}
