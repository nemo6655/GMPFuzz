import re

with open('test.tex', 'r') as f:
    text = f.read()

old_str = r"""Second, the fuzzer must handle dynamic semantic constraints. In MQTT v5.0, a broker dictates a \texttt{Topic Alias Maximum} during the initial \texttt{CONNACK}. To exercise the alias resolution, the client must perfectly map a string to an integer within this bound, and then reuse that integer in subsequent packets. Generation-based fuzzers like \textbf{MPFuzz} rely on static, predefined templates. Because MPFuzz lacks semantic reasoning across states, it fails to dynamically tie the broker's runtime parameters to future payloads, typically exceeding boundary checks or failing the two-step mapping sequence entirely."""

new_str = r"""Second, the fuzzer must handle dynamic semantic constraints based on the broker's real-time responses. In MQTT v5.0, a broker specifically dictates a \texttt{Topic Alias Maximum} during the initial \texttt{CONNACK}. To effectively exercise alias resolution, the client must perfectly map a full topic string to an alias integer within this strict bound, and then consistently reuse that integer in subsequent \texttt{PUBLISH} packets. Although recent generation-based fuzzers like \textbf{MPFuzz} introduce semantic-aware field synchronization to improve parallel fuzzing, their underlying mechanisms still fundamentally rely on static, manually predefined templates (e.g., Peach Pit models). Because MPFuzz lacks dynamic state reasoning to extract live constraints from broker responses, it fails to dynamically tie parameters like \texttt{Topic Alias Maximum} to future payloads. Consequently, it typically exceeds boundary checks or fails the multi-step mapping sequence entirely."""

if old_str in text:
    print("Found! Patching...")
    text = text.replace(old_str, new_str)
    with open('test.tex', 'w') as f:
        f.write(text)
else:
    print("Not found.")
