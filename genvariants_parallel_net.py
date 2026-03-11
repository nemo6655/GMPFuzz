#!/usr/bin/env python3
"""
genvariants_parallel_net.py - Use a code model (e.g., CodeLlama) to generate
variants of MQTT seed generator Python files via infilling, splicing, and completion.

Input: Python seed files containing MQTT packet generator functions.
Output: Python variant files with LLM-mutated packet generation code.

The variants are printed to stdout (one path per line) and can be piped
to genoutputs_net.py for execution.
"""

import json
import random
import os
import sys
from typing import List, Optional, Dict
from argparse import ArgumentParser
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed
import textwrap
import signal
import re

# Global flag for graceful shutdown
shutdown_requested = False

def signal_handler(signum, frame):
    global shutdown_requested
    print(f"Received signal {signum}, requesting shutdown...", file=sys.stderr)
    shutdown_requested = True

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


def get_endpoints() -> Dict[str, str]:
    result = dict()
    endpoint_list = os.getenv('ENDPOINTS', '').split(' ')
    for endpoint_pair in endpoint_list:
        if ':' in endpoint_pair:
            (model, endpoint) = endpoint_pair.split(':', 1)
            result[model] = endpoint
    return result


def model_info():
    """Get information about the model."""
    endpoints = get_endpoints()
    endpoint = list(endpoints.values())[0] if endpoints else None
    if not endpoint:
        raise ValueError("No model endpoint configured")
    return requests.get(f'{endpoint}/info', timeout=30).json()


def generate_completion(
        prompt,
        temperature=0.2,
        max_new_tokens=1200,
        repetition_penalty=1.1,
        stop=None,
):
    """Generate a completion of the prompt using the LLM endpoint."""
    endpoints = get_endpoints()
    endpoint = list(endpoints.values())[0] if endpoints else None
    if not endpoint:
        raise ValueError("No model endpoint configured")

    data = {
        'inputs': prompt,
        'parameters': {
            'temperature': temperature,
            'max_new_tokens': max_new_tokens,
            'do_sample': True,
            'repetition_penalty': repetition_penalty,
            'details': True,
        },
    }
    if stop is not None:
        data['parameters']['stop'] = stop
    try:
        response = requests.post(f'{endpoint}/generate', json=data, timeout=300)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.Timeout:
        print(f"Request timed out after 300 seconds", file=sys.stderr)
        return {"error": "Request timeout"}
    except requests.exceptions.RequestException as e:
        error_res = {"error": f"Request failed: {e}"}
        if e.response is not None:
            error_res["response_text"] = e.response.text
        return error_res
    except Exception as e:
        return {"error": f"Unexpected error: {e}"}


def infilling_prompt_llama(pre: str, suf: str) -> str:
    return f'<PRE> {pre} <SUF>{suf} <MID>'


def infilling_prompt_qwen(pre: str, suf: str) -> str:
    return f'<|fim_prefix|>{pre}<|fim_suffix|>{suf}<|fim_middle|>'


def infilling_prompt_starcoder(pre: str, suf: str) -> str:
    return f'<fim_prefix>{pre}<fim_suffix>{suf}<fim_middle>'


# Default infilling prompt function
infilling_prompt = infilling_prompt_llama


def get_mutable_limit(text: str) -> int:
    """Find the line number where the __mqtt_gen__ or similar function is defined."""
    lines = text.split('\n')
    for i, line in enumerate(lines):
        if re.match(r'^\s*def\s+(?:__)?\w+_gen(?:__)?\s*\(', line) and not re.search(r'\):\s*return', line):
            return i
    return len(lines)


def random_completion(text: str, start_line: int = 1) -> tuple:
    text_lines = text.split('\n')
    limit = get_mutable_limit(text)
    effective_len = min(len(text_lines), limit)
    cut_line = effective_len - 2 if start_line + 1 >= effective_len - 1 else random.randint(start_line + 1, effective_len - 1)
    prompt_text = '\n'.join(text_lines[:cut_line])
    real_completion = '\n'.join(text_lines[cut_line:])
    return prompt_text, real_completion


def random_fim(text: str, start_line: int = 1) -> tuple:
    text_lines = text.split('\n')
    limit = get_mutable_limit(text)
    effective_len = min(len(text_lines), limit)
    fim_start_line = effective_len - 3 if start_line + 1 >= effective_len - 2 else random.randint(start_line + 1, effective_len - 2)
    fim_end_line = random.randint(fim_start_line + 1, effective_len - 1)
    prefix_text = '\n'.join(text_lines[:fim_start_line]) + '\n'
    suffix_text = '\n'.join(text_lines[fim_end_line:])
    real_middle = '\n'.join(text_lines[fim_start_line:fim_end_line])
    return prefix_text, suffix_text, real_middle


def random_crossover(text1: str, text2: str, start_line: int = 1) -> tuple:
    text_lines1 = text1.split('\n')
    text_lines2 = text2.split('\n')
    limit1 = get_mutable_limit(text1)
    limit2 = get_mutable_limit(text2)
    effective_len1 = min(len(text_lines1), limit1)
    effective_len2 = min(len(text_lines2), limit2)

    common_prefix = 0
    for i in range(min(effective_len1, effective_len2)):
        if text_lines1[i] != text_lines2[i]:
            common_prefix = i - 1
            break

    cut_line1 = effective_len1 - 2 if start_line + 1 >= effective_len1 - 1 else random.randint(start_line + 1, effective_len1 - 1)
    may_overlap = min(cut_line1 - 1, common_prefix)
    cut_line2_start = max(may_overlap, start_line)
    cut_line2 = effective_len2 - 2 if cut_line2_start + 1 >= effective_len2 - 1 else random.randint(cut_line2_start + 1, effective_len2 - 1)

    prefix = '\n'.join(text_lines1[:cut_line1])
    suffix = '\n'.join(text_lines2[cut_line2:])
    return prefix, suffix


def continue_completion(text: str) -> tuple:
    text_lines = text.split('\n')
    limit = get_mutable_limit(text)
    cut_line = limit if limit < len(text_lines) else len(text_lines)
    prompt_text = '\n'.join(text_lines[:cut_line])
    return prompt_text, ''


def clean_markdown(text):
    lines = text.split('\n')
    if lines and lines[0].strip().startswith('```'):
        lines = lines[1:]
    if lines and lines[-1].strip().startswith('```'):
        lines = lines[:-1]
    return '\n'.join(lines)


def fix_unclosed_strings(text):
    quote_char = None
    escaped = False
    for char in text:
        if escaped:
            escaped = False
            continue
        if char == '\\':
            escaped = True
            continue
        if quote_char:
            if char == quote_char:
                quote_char = None
        else:
            if char in '"\'':
                quote_char = char
    if quote_char:
        text += quote_char
    return text


def fix_indentation(prefix, text):
    lines = text.split('\n')
    if not lines:
        return text
    prefix_lines = prefix.split('\n')
    last_prefix_line = prefix_lines[-1] if prefix_lines else ""
    should_indent = last_prefix_line.strip().endswith(':')
    first_non_empty_idx = -1
    for i, line in enumerate(lines):
        if line.strip():
            first_non_empty_idx = i
            break
    if first_non_empty_idx == -1:
        return text
    first_line = lines[first_non_empty_idx]
    first_line_indent = len(first_line) - len(first_line.lstrip())
    if should_indent and first_line_indent == 0:
        return '\n'.join(['    ' + line for line in lines])
    elif not should_indent and first_line_indent > 0:
        return textwrap.dedent(text)
    return text


def check_and_fix_balance(text):
    stack = []
    mapping = {')': '(', ']': '[', '}': '{'}
    reverse_mapping = {'(': ')', '[': ']', '{': '}'}
    for char in text:
        if char in '([{':
            stack.append(char)
        elif char in ')]}':
            if stack and stack[-1] == mapping[char]:
                stack.pop()
    suffix = ""
    while stack:
        opener = stack.pop()
        suffix += reverse_mapping[opener]
    return text + suffix


def new_base(filename: str) -> tuple:
    base = os.path.basename(filename)
    base, ext = os.path.splitext(base)
    first = base.find('.base_')
    if first == -1:
        return base, ext
    else:
        return base[:first], ext


def generate_variant(i, generators, model, filename, args):
    """Generate a single variant of a seed file using the LLM."""
    generator = random.choice(generators)

    instruction = (
        "# Context: This is a polished seed file for generating MQTT protocol fuzzing packets.\n"
        "# Goal: Analyze the existing MQTT protocol request fuzzing functions in the seed file.\n"
        "# Task: Generate similar protocol fuzzing functions for the MQTT protocol.\n"
        "# Requirements:\n"
        "# 1. Maintain the same structure, return type (bytes), and MQTT binary packet format.\n"
        "# 2. Generate diverse requests to cover different protocol states and edge cases.\n"
        "# 3. Ensure the generated code is syntactically correct Python.\n"
    )

    if generator == 'infilled':
        prefix, suffix, orig = random_fim(open(filename).read(), args.start_line)
        prefix = instruction + prefix
        prompt = infilling_prompt(prefix, suffix)
        stop = []
    elif generator == 'lmsplice':
        other_files = [f for f in args.files if f != filename]
        if other_files:
            filename2 = random.choice(other_files)
        else:
            filename2 = filename
        prefix, suffix = random_crossover(open(filename).read(), open(filename2).read(), args.start_line)
        orig = ''
        prefix = instruction + prefix
        prompt = infilling_prompt(prefix, suffix)
        stop = []
    else:
        # complete
        prefix, orig = random_completion(open(filename).read(), args.start_line)
        text_content = open(filename).read()
        limit = get_mutable_limit(text_content)
        text_lines = text_content.split('\n')
        suffix = '\n'.join(text_lines[limit:]) if limit < len(text_lines) else ''
        prefix = instruction + prefix
        prompt = prefix
        stop = ['\nif', '\nclass', '\nfor', '\nwhile']

    base, ext = new_base(filename)
    plines = prefix.count('\n')
    slines = suffix.count('\n')
    olines = orig.count('\n') if isinstance(orig, str) else 0

    out_file = f'var_{i:04}.{generator}{ext}'
    out_path = os.path.join(args.output_dir, out_file)
    meta_file = os.path.join(args.log_dir, out_file + '.json')

    gen_params = {}
    if hasattr(args, 'gen'):
        gen_params = vars(args.gen)

    res = generate_completion(prompt, stop=stop, **gen_params)

    if 'generated_text' not in res:
        meta = {
            'model': model,
            'generator': generator,
            'prompt_lines': plines,
            'orig_lines': olines,
            'gen_lines': 0,
            'suffix_lines': slines,
            'finish_reason': 'err',
            'base': [base],
            'response': res,
        }
        with open(meta_file, 'w') as f:
            f.write(json.dumps(meta))
        return None

    text = res['generated_text']
    if 'codellama' in model:
        text = text.replace(' <EOT>', '')
        for stop_seq in (stop or []):
            if text.endswith(stop_seq):
                text = text[:-len(stop_seq)]

    text = clean_markdown(text)
    text = fix_indentation(prefix, text)
    text = fix_unclosed_strings(text)
    full_text = prefix + text
    balanced_full_text = check_and_fix_balance(full_text)
    added_suffix = balanced_full_text[len(full_text):]
    text += added_suffix

    gen_lines = text.count('\n')
    finish_reason = res.get('details', {}).get('finish_reason', 'unknown')
    finish_reason = {
        'length': 'len', 'eos_token': 'eos', 'stop_sequence': 'stp',
    }.get(finish_reason, finish_reason)

    meta = {
        'model': model,
        'generator': generator,
        'prompt_lines': plines,
        'orig_lines': olines,
        'gen_lines': gen_lines,
        'suffix_lines': slines,
        'finish_reason': finish_reason,
        'base': [base],
    }

    mutable_content = prefix + text
    try:
        import autopep8
        mutable_content = autopep8.fix_code(mutable_content)
    except Exception:
        pass

    if suffix and not mutable_content.endswith('\n\n'):
        if mutable_content.endswith('\n'):
            mutable_content += '\n'
        else:
            mutable_content += '\n\n'

    full_content = mutable_content + suffix

    with open(out_path, 'w') as f:
        f.write(full_content)
    with open(meta_file, 'w') as f:
        f.write(json.dumps(meta))

    return out_path


def make_parser():
    parser = ArgumentParser(
        description='Use a code model to generate variants of MQTT seed files.'
    )
    parser.add_argument('files', type=str, nargs='+',
                        help='Input Python seed files')
    parser.add_argument('-M', '--model_name', type=str, default='codellama/CodeLlama-13b-hf',
                        help='Model to use for generation')
    parser.add_argument('--no-completion', action='store_true',
                        help='Disable the completion mutator')
    parser.add_argument('--no-fim', action='store_true',
                        help='Disable the FIM (infilling) mutator')
    parser.add_argument('--no-splice', action='store_true',
                        help='Disable the splice mutator')
    parser.add_argument('-n', '--num_variants', type=int, default=1,
                        help='Number of variants to generate for each seed')
    parser.add_argument('-O', '--output_dir', type=str, default='.',
                        help='Directory to write variants to')
    parser.add_argument('-L', '--log_dir', type=str, default='logs',
                        help='Directory to write generation metadata to')
    parser.add_argument('-s', '--start_line', type=int, default=0,
                        help='When making random cuts, always start at this line')
    parser.add_argument('-j', '--jobs', type=int, default=16,
                        help='Number of inference jobs to run in parallel')
    # Generation params
    parser.add_argument('-t', '--gen.temperature', type=float, default=0.2,
                        help='Generation temperature')
    parser.add_argument('-m', '--gen.max-new-tokens', type=int, default=2048,
                        help='Maximum number of tokens to generate')
    parser.add_argument('-r', '--gen.repetition-penalty', type=float, default=1.1,
                        help='Repetition penalty')
    return parser


def main():
    global infilling_prompt

    parser = make_parser()
    args = parser.parse_args()

    # Try to get model info and set the correct infilling prompt
    try:
        info = model_info()
        model = info.get('model_id', args.model_name)
        if 'starcoder' in model.lower():
            infilling_prompt = infilling_prompt_starcoder
        elif 'qwen' in model.lower():
            infilling_prompt = infilling_prompt_qwen
        else:
            infilling_prompt = infilling_prompt_llama
    except Exception as e:
        print(f"Warning: Could not get model info: {e}", file=sys.stderr)
        model = args.model_name
        infilling_prompt = infilling_prompt_llama

    os.makedirs(args.output_dir, exist_ok=True)
    os.makedirs(args.log_dir, exist_ok=True)

    forbidden = os.environ.get('ELFUZZ_FORBIDDEN_MUTATORS', '').split(',')
    forbidden = [f.strip() for f in forbidden if f.strip()]

    generators = []
    if not args.no_completion and 'complete' not in forbidden:
        generators += ['complete']
    if not args.no_fim and 'infilled' not in forbidden:
        generators += ['infilled']
    if not args.no_splice and 'lmsplice' not in forbidden:
        generators += ['lmsplice']

    if not generators:
        print("Error: No generators enabled", file=sys.stderr)
        sys.exit(1)

    # Print the count for genoutputs
    print(len(args.files) * args.num_variants, flush=True)

    worklist = []
    i = 0
    for _ in range(args.num_variants):
        for filename in args.files:
            worklist.append((i, filename))
            i += 1

    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = []
        for i, filename in worklist:
            if shutdown_requested:
                break
            future = executor.submit(generate_variant, i, generators, model, filename, args)
            futures.append(future)

        for future in as_completed(futures):
            if shutdown_requested:
                for f in futures:
                    if not f.done():
                        f.cancel()
                break
            try:
                res = future.result()
                if res is not None:
                    print(res, flush=True)
            except Exception as e:
                print(f"Error generating variant: {e}", file=sys.stderr)


if __name__ == '__main__':
    main()
