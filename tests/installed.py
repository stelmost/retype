#!/usr/bin/env python3
"""Check an exact native preview archive, not the signed installed tier."""
import argparse
import functools
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import tomllib


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_digests(directory):
    return {path: sha(path) for path in directory.rglob('*') if path.is_file()}


def review_inputs(work, state):
    return (file_digests(work) | file_digests(state / 'undo') | file_digests(state / 'recovery') |
            {state / 'jobs.jsonl': sha(state / 'jobs.jsonl')})


def remove_windows_installation(run, installer, env):
    run('uninstall', installer, child_env=env | {'RETYPE_ACTION': 'remove'})


def without_installer_path(current, before, binary_dir):
    if current is None:
        return None
    owned = str(binary_dir).casefold()
    if any(entry.casefold() == owned for entry in (before or '').split(';')):
        return current
    entries = [entry for entry in current.split(';') if entry.casefold() != owned]
    return None if not entries and before is None else ';'.join(entries)


def installed_fidelity_matches_builds(job, manifest):
    if not job['outputs'] or manifest.get('version', 'retype-fidelity-1') != 'retype-fidelity-1':
        return False
    engine = (job.get('engine') or {}).get('candidate')
    defaults = {'engine': None, 'version': '', 'fingerprint': '', 'engine_version': '',
                'engine_fingerprint': '', 'axes': [], 'lost': []}
    for output in job['outputs']:
        evidence = output['fidelity']
        claim = evidence.get('claim')
        record = next((record for record in manifest.get('claim', []) if
                       (record['source'], record['target'], record['backend'], record.get('engine')) ==
                       (job['source']['format'], output['format'], job['backend'], engine)), None)
        if not record or not claim or {**defaults, **record} != {**defaults, **claim}:
            return False
        builds_match = all(evidence[field] == record.get(field, '') for field in
                           ('version', 'fingerprint', 'engine_version', 'engine_fingerprint'))
        if evidence['state'] != ('earned' if builds_match else 'unverified'):
            return False
    return True


def preserve_fixture(private, report):
    backup = report / 'failed-fixture'
    if not backup.exists():
        shutil.copytree(private, backup, ignore=lambda folder, names: [name for name in names
                        if stat.S_ISSOCK((Path(folder) / name).lstat().st_mode)])


def record_integration_paths(report, label, paths):
    effects = {}
    for path in paths:
        effects[str(path)] = {'exists': path.exists(), 'symlink': path.is_symlink()}
        if path.is_symlink():
            effects[str(path)]['target'] = os.readlink(path)
    (report / f'{label}.json').write_text(json.dumps(effects, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--report', required=True, type=Path)
    scope = parser.add_mutually_exclusive_group(required=True)
    scope.add_argument('--preview', action='store_true', help='Check a Linux/macOS preview archive, not signed delivery')
    scope.add_argument('--preview-cli-only', action='store_true',
                       help='Check Windows unsigned preview CLI/data smoke, including owned user-PATH cleanup')
    parser.add_argument('--allow-user-integration', action='store_true',
                        help='Acknowledge an approved profile for macOS registration or Windows user-PATH mutation')
    args = parser.parse_args()
    windows = os.name == 'nt'
    macos = sys.platform == 'darwin'
    linux = sys.platform.startswith('linux')
    if not (windows or macos or linux):
        parser.error('Run on native Linux, macOS or Windows')
    if windows != args.preview_cli_only:
        parser.error('Windows requires --preview-cli-only; other hosts require --preview. Signed qualification is separate')
    scope = 'unsigned-preview-cli-data-smoke' if windows else 'preview-archive'
    if (macos or windows) and not args.allow_user_integration:
        change = 'application registration' if macos else 'PATH'
        parser.error(f'{sys.platform} changes current-user {change}; approve a disposable session first')
    application_link = Path.home() / 'Applications/retype.app'
    macos_unit = Path.home() / 'Library/LaunchAgents/com.lapilliworks.retype.cli.plist'
    if macos:
        assert not any(path.exists() or path.is_symlink() for path in (application_link, macos_unit)), \
            'Refusing to replace existing macOS user integration'
    archive = args.archive.resolve()
    report = args.report.resolve()
    report.mkdir(parents=True, exist_ok=True)
    (report / 'scope.json').write_text(json.dumps({'scope': scope, 'install_mode': 'preview'}, indent=2) + '\n')
    print(f'Scope: {scope}; not signed installed-tier qualification', flush=True)
    repo = Path(__file__).resolve().parent.parent
    assert archive.name.endswith('.tar.gz')
    with tarfile.open(archive) as package:
        roots = {Path(member.name).parts[0] for member in package.getmembers()}
    assert len(roots) == 1
    name = roots.pop()
    architecture = 'x86_64' if 'x86_64' in name else 'aarch64'
    platform = 'pc-windows-msvc' if windows else 'apple-darwin' if macos else 'unknown-linux-gnu'
    suffix = f'-{architecture}-{platform}'
    assert name.startswith('retype-') and name.endswith(suffix)
    tag = name[len('retype-'):-len(suffix)]
    checks = []
    processes = []
    server = None
    original_path = None
    installer_attempted = False
    uninstalled = False
    # User integration may outlive a failed install; preserve its original prefix until cleanup is checked.
    with tempfile.TemporaryDirectory(prefix='rt-installed-', dir=None if windows else '/tmp',
                                     delete=linux) as private:
        private = Path(private)
        (report / 'private-path.txt').write_text(str(private) + '\n')
        work = private / 'work'
        work.mkdir()
        prefix = private / 'prefix'
        state = private / 'state'
        mirror = private / 'releases' / tag
        mirror.mkdir(parents=True)
        shutil.copy2(archive, mirror / archive.name)
        (mirror / 'SHA256SUMS').write_text(f'{sha(archive)}  {archive.name}\n')
        config = private / 'config.toml'
        config.write_text("version = 'retype-config-1'\n[notify]\nenabled = false\n[deferral]\nmode = 'now'\n")
        env = os.environ.copy()
        for key in ['RETYPE_DAEMON', 'RETYPE_NO_SPAWN', 'RETYPE_STATE_DIR', 'RETYPE_FIDELITY_MANIFEST',
                    'RETYPE_FIXTURES', 'RETYPE_TEST_SESSION', 'RETYPE_STARTUP', 'RETYPE_ACTION']:
            env.pop(key, None)
        env['RETYPE_CONFIG'] = str(config)
        env['RETYPE_STATE_DIR'] = str(state)
        env['RETYPE_RELEASE_BASE'] = mirror.parent.as_uri()
        env['RETYPE_TARGET'] = suffix[1:]
        env['RETYPE_VERSION'] = tag
        env['RETYPE_PREFIX'] = str(prefix)
        env['RETYPE_INSTALL_MODE'] = 'preview'
        env['XDG_CONFIG_HOME'] = str(private / 'config')
        env['XDG_STATE_HOME'] = str(private / 'state-home')
        env['XDG_DATA_HOME'] = str(private / 'data')
        binary = prefix / 'bin' / ('retype.exe' if windows else 'retype')
        installer = (['pwsh', '-NoProfile', '-NonInteractive', '-File', repo / 'packaging/install.ps1'] if windows
                     else ['bash', repo / 'packaging/install.sh', '--version', tag, '--prefix', prefix])

        def stop_process(process):
            if windows:
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
            else:
                os.killpg(process.pid, signal.SIGKILL)

        def run(label, command, success=True, timeout=40, *, child_env=None):
            process = subprocess.Popen([str(part) for part in command], cwd=work,
                                       env=env if child_env is None else child_env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            processes.append(process)
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                stop_process(process)
                stdout, stderr = process.communicate()
                raise AssertionError(f'{label} timed out')
            (report / f'{label}.stdout.log').write_bytes(stdout)
            (report / f'{label}.stderr.log').write_bytes(stderr)
            assert (process.returncode == 0) == success, (label, process.returncode, stdout.decode(errors='replace'), stderr.decode(errors='replace'))
            return stdout.decode()

        def user_path(label):
            return run(label, ['pwsh', '-NoProfile', '-NonInteractive', '-Command',
                       "ConvertTo-Json -InputObject ([Environment]::GetEnvironmentVariable('Path', 'User'))"])

        def cli(label, *parts, success=True):
            result = json.loads(run(label, [binary, *parts, '--json', '--state-dir', state], success))
            assert result['ok'] == success, result
            return result

        def check(label, condition):
            assert condition, label
            checks.append(label)
            (report / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
            print(f'PASS ({scope}):' if windows else 'PASS:', label, flush=True)

        def undo(label, job):
            cli(label, 'undo', job['id'])

        def convert_heic(label, source):
            shutil.copy2(repo / 'fixtures/native-watch/photo.heic', source)
            source.with_suffix('.webp').write_bytes(b'unowned adjacent file\0\xff')
            original = file_digests(work)
            job = cli(label, 'convert', source, 'jpg')['job']
            output = source.with_suffix('.jpg')
            converted = original.copy()
            del converted[source]
            check(f'{label}: real HEIC disposition', job['source_disposition']['state'] == 'removed' and
                  output.is_file() and file_digests(work) == (converted | {output: sha(output)}))
            return job, original

        def refuse_review_requests(job):
            uri = f'retype://job/{job["id"]}'
            assert (state / 'undo' / job['id'] / 'meta.toml').is_file(), 'HEIC conversion must have an undo record'
            before = review_inputs(work, state)
            # The fixture selects RETYPE_STATE_DIR in the child environment, not through the request.
            for label, command in (
                ('uri-legacy-undo', ['uri', '--', uri + '?action=undo']),
                ('uri-short-id', ['uri', '--', uri[:-1]]),  # A unique job prefix, not a full ID.
                ('uri-json', ['--json', 'uri', '--', uri]),
            ):
                (report / f'{label}.requested').write_text(command[-1] + '\n')
                result = run(label, [binary, *command], success=False)
                if '--json' in command and result.strip():
                    assert json.loads(result)['ok'] is False, result
                check(f'{label} refuses without changing files, recovery or journal', before == review_inputs(work, state))

        def stop(label):
            if binary.exists() and (state / 'endpoint').exists():
                run(label, [binary, 'daemon', 'stop', '--now', '--force', '--no-spawn', '--state-dir', state], timeout=15)
                deadline = time.monotonic() + 5
                while (state / 'endpoint').exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                assert not (state / 'endpoint').exists(), 'test daemon leaked'

        def cleanup():
            try:
                for process in processes:
                    if process.poll() is None:
                        stop_process(process)
                        process.wait()
                stop('stop')
            finally:
                if server:
                    server.shutdown()
                    server.server_close()
                if macos and installer_attempted:
                    record_integration_paths(report, 'integration-before-cleanup', (application_link, macos_unit))
                    if not uninstalled:
                        run('cleanup-uninstall', ['bash', repo / 'packaging/install.sh', '--uninstall', '--prefix', prefix])
                    record_integration_paths(report, 'integration-after-cleanup', (application_link, macos_unit))
                    assert not any(path.exists() or path.is_symlink() for path in (application_link, macos_unit)), \
                        'User integration remains; retaining its original fixture path'
                if original_path is not None:
                    current = json.loads(user_path('user-path-after'))
                    before = json.loads(original_path)
                    restored = without_installer_path(current, before, binary.parent)
                    if restored != current:
                        run('restore-owned-user-path', ['pwsh', '-NoProfile', '-NonInteractive', '-Command',
                            "$before = $env:RETYPE_TEST_USER_PATH_BEFORE | ConvertFrom-Json; "
                            "if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $before) "
                            "{ throw 'User PATH changed; refusing fixture cleanup replacement.' }; "
                            "$value = $env:RETYPE_TEST_USER_PATH_RESTORED | ConvertFrom-Json; "
                            "[Environment]::SetEnvironmentVariable('Path', $value, 'User')"],
                            child_env=env | {'RETYPE_TEST_USER_PATH_BEFORE': json.dumps(current),
                                             'RETYPE_TEST_USER_PATH_RESTORED': json.dumps(restored)})
                    verified = json.loads(user_path('user-path-cleaned'))
                    if without_installer_path(before, None, binary.parent) == before:
                        assert without_installer_path(verified, None, binary.parent) == verified, \
                            'Installer-added user PATH token remains; retaining its original fixture path'

        try:
            if macos:
                record_integration_paths(report, 'integration-before-install', (application_link, macos_unit))
            if windows:
                original_path = user_path('user-path-before')
                handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(mirror.parent))
                server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                env['RETYPE_RELEASE_BASE'] = f'http://127.0.0.1:{server.server_port}'
            installer_attempted = True
            run('install', installer)
            check('installed executable and evidence exist', binary.is_file() and (prefix / 'share/retype/fidelity.toml').is_file())
            with tarfile.open(archive) as package:
                member = package.extractfile(f'{name}/bin/{binary.name}')
                assert member and hashlib.sha256(member.read()).hexdigest() == sha(binary), \
                    'Installed executable differs from the exact archive'
                member = package.extractfile(f'{name}/share/retype/fidelity.toml')
                assert member, 'Exact archive lacks its fidelity manifest'
                packaged_fidelity = member.read()
                assert (prefix / 'share/retype/fidelity.toml').read_bytes() == packaged_fidelity, \
                    'Installed fidelity manifest differs from the exact archive'
                manifest = tomllib.loads(packaged_fidelity.decode('utf-8'))
            if windows:
                executable = binary.read_bytes()
                pe = int.from_bytes(executable[60:64], 'little')
                machine = int.from_bytes(executable[pe + 4:pe + 6], 'little')
                check('native executable architecture', executable[pe:pe + 4] == b'PE\0\0' and
                      machine == (0xAA64 if architecture == 'aarch64' else 0x8664))
                installed_path = json.loads(user_path('user-path-installed'))
                check('preview user PATH token',
                      installed_path != without_installer_path(installed_path, None, binary.parent))
            if linux:
                desktop = Path(env['XDG_DATA_HOME']) / 'applications/retype-uri.desktop'
                unit = Path(env['XDG_CONFIG_HOME']) / 'systemd/user/retype.service'
                check('desktop identity and disabled user unit', desktop.is_file() and unit.is_file() and
                      not list(unit.parent.glob('*.wants/retype.service')))
                run('desktop-validate', ['desktop-file-validate', desktop])
                check('installed URI association', run('mime-default', ['xdg-mime', 'query', 'default',
                      'x-scheme-handler/retype']).strip() == 'retype-uri.desktop')
                exec_line = next(line for line in desktop.read_text().splitlines() if line.startswith('Exec='))
                check('installed URI handler targets the exact binary',
                      shlex.split(exec_line.removeprefix('Exec=')) == ['/usr/bin/env', str(binary), 'uri', '--', '%u'])
            if macos:
                app = prefix / 'share/retype/macos/retype.app'
                notifier = app / 'Contents/MacOS/retype-notifier'
                check('macOS bundle and disabled startup', notifier.is_file() and
                      sha(app / 'Contents/Resources/retype') == sha(binary) and not macos_unit.exists())
                check('installed URI association and owned app link', application_link.is_symlink() and
                      application_link.resolve() == app.resolve() and
                      run('macos-uri-default', [notifier, 'handler']).strip() == 'com.lapilliworks.retype.cli')
            run('version', [binary, 'version'])
            run('doctor', [binary, 'doctor', '--check', '--state-dir', state])
            job, original = convert_heic('heic', work / 'photo.HEIC')
            refuse_review_requests(job)
            cli('online-daemon-status', 'daemon', 'status', '--no-spawn')
            undo('online-heic-undo', job)
            check('online CLI undo restores exact HEIC and removes only its output', file_digests(work) == original)
            png = work / 'image.png'
            shutil.copy2(repo / 'fixtures/fidelity/alpha.png', png)
            expected = sha(png)
            job = cli('multi-output', 'convert', png, 'jpg,webp+keep', '--no-spawn')['job']
            check('installed fidelity lookup', installed_fidelity_matches_builds(job, manifest))
            undo('multi-output-undo', job)
            check('kept source and outputs after undo', sha(png) == expected and all(not Path(output['path']).exists() for output in job['outputs']))
            document = work / 'document.md'
            document.write_text('# Report\n\nA paragraph, **emphasis**, and $x^2$.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n')
            expected = sha(document)
            job = cli('pdf', 'convert', document, 'pdf', '--no-spawn')['job']
            check('selected Typst produces PDF', Path(job['engine']['candidate']).stem == 'typst' and (work / 'document.pdf').read_bytes().startswith(b'%PDF'))
            undo('pdf-undo', job)
            check('document undo', sha(document) == expected and not (work / 'document.pdf').exists())
            source = work / 'archive.tar'
            with tarfile.open(source, 'w', format=tarfile.GNU_FORMAT) as package:
                member = tarfile.TarInfo('payload.txt')
                member.mode = 0o600
                member.mtime = 1700000000
                member.size = 7
                package.addfile(member, io.BytesIO(b'payload'))
            expected = sha(source)
            job = cli('archive', 'convert', source, 'zip', '--no-spawn')['job']
            undo('archive-undo', job)
            check('native archive exact undo', sha(source) == expected and not source.with_suffix('.zip').exists())
            damaged = work / 'bad.heic'
            damaged.write_bytes(b'invalid source')
            cli('decoder-refusal', 'convert', damaged, 'jpg', '--no-spawn', success=False)
            check('failure preserves source', damaged.read_bytes() == b'invalid source' and not damaged.with_suffix('.jpg').exists())
            offline_job, original = convert_heic('offline-job', work / 'offline.HEIC')
            before = sha(binary)
            stop('stop-before-update')
            run('update', installer)
            backups = (prefix / 'share').glob('retype-backup-*' if windows else 'retype-backup.*')
            check('update backup', sha(binary) == before and any((backup / binary.name).is_file() and sha(backup / binary.name) == before for backup in backups))
            (mirror / 'SHA256SUMS').write_text(f'{"0" * 64}  {archive.name}\n')
            run('checksum-refusal', installer, False)
            check('checksum failure preserves installation', sha(binary) == before)
            check('offline CLI undo starts without a daemon', not (state / 'endpoint').exists())
            daemon_log = sha(state / 'daemon.log')
            undo('offline-heic-undo', offline_job)
            check('offline CLI undo restores exact HEIC and removes only its output', file_digests(work) == original)
            check('offline CLI undo does not spawn a daemon', not (state / 'endpoint').exists() and
                  sha(state / 'daemon.log') == daemon_log)
            journal = (state / 'jobs.jsonl').read_bytes()
            if windows:
                current = json.loads(user_path('user-path-before-uninstall'))
                expected_path = without_installer_path(current, json.loads(original_path), binary.parent)
                remove_windows_installation(run, installer, env)
                removed_path = json.loads(user_path('user-path-uninstalled'))
                # Windows may represent an empty user PATH as absent.
                check('uninstall removes only owned user PATH token', (removed_path or '') == (expected_path or ''))
            else:
                run('uninstall', ['bash', repo / 'packaging/install.sh', '--uninstall', '--prefix', prefix])
            if linux:
                check('uninstall preserves state and removes integration', not binary.exists() and
                      not desktop.exists() and not unit.exists() and (state / 'jobs.jsonl').read_bytes() == journal)
            else:
                check('uninstall preserves state', not binary.exists() and (state / 'jobs.jsonl').read_bytes() == journal)
                if macos:
                    check('macOS removal clears owned user integration', not application_link.is_symlink() and
                          not application_link.exists() and not macos_unit.exists())
            uninstalled = True
        except BaseException:
            preserve_fixture(private, report)
            if macos:
                record_integration_paths(report, 'integration-failed-install', (application_link, macos_unit))
            raise
        finally:
            try:
                cleanup()
            except BaseException:
                preserve_fixture(private, report)
                (report / 'retained-private-path.txt').write_text(str(private) + '\n')
                if macos:
                    record_integration_paths(report, 'integration-failed-cleanup', (application_link, macos_unit))
                raise
            else:
                if not linux:
                    shutil.rmtree(private)
    (report / 'result.json').write_text(json.dumps({
        'checks': len(checks), 'archive': str(archive), 'sha256': sha(archive),
        'target': suffix[1:], 'install_mode': 'preview', 'scope': scope,
    }, indent=2) + '\n')
    print(f'{len(checks)} installed-archive checks passed ({scope}; not signed installed-tier qualification)')


if __name__ == '__main__':
    main()
