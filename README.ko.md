# notifysound

**에이전트가 턴을 끝내면 소리가 난다 — Claude Code와 Codex CLI를 스위치 하나로.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

English: [README.md](./README.md)

터미널 알림음 설정은 대개 도구별로 흩어진다. 여기에 훅 하나, 저기에 셸 별칭
하나, 각자 다른 켜고 끄는 방식과 각자 다른 음원 위치. notifysound는 반대로 간다 —
상태는 CLI 하나가 소유하고, 하네스 훅은 전부 같은 재생기를 호출하는 얇은 껍데기일
뿐이다. Claude Code는 그대로 두고 Codex만 조용히 시키는 일이 설정 파일 편집이
아니라 명령 한 줄이다.

재생기는 의도적으로 시스템에서 가장 멍청한 부분이다. 어떤 실패 경로에서도 exit 0에
stdout 무출력이므로, 파일이 없거나 config가 깨졌거나 심링크가 끊어져도 에이전트 턴을
막거나 망가뜨릴 수 없다. 판단은 전부 CLI에 있다.

## 요구 사항

- **macOS.** 재생은 `afplay`를 쓴다. Linux·Windows는 지원하지 않는다 —
  `paplay`/`aplay` 추상화는 별도 작업이다.
- `bash`와 [`jq`](https://jqlang.github.io/jq/) (`brew install jq`).
- Claude Code, Codex CLI, 또는 둘 다. 둘 다 필수는 아니다 — notifysound는 발견된
  쪽에만 훅을 설치한다.

## 설치

### 방법 A — `skills add`

```bash
skills add dandacompany/notifysound@notifysound -g --copy -a claude-code
notifysound install
```

두 번째 줄은 선택이 아니다. 스킬 매니저는 스킬 파일만 배치하고 홈 설정 파일은
의도적으로 건드리지 않으므로, 훅 설치는 명시적 행위로 남는다.
`notifysound install`이 훅을 쓰고 빌트인 음원을 등록한다.

### 방법 B — 원라이너

```bash
curl -fsSL https://raw.githubusercontent.com/dandacompany/notifysound/main/install.sh | bash
```

스크립트를 `bash`로 파이프한다는 건 읽지 않은 코드를 실행한다는 뜻이고, 이 스크립트는
홈 디렉터리의 파일을 편집한다. 2단계 방식이 더 나은 습관이다.

```bash
curl -fsSL https://raw.githubusercontent.com/dandacompany/notifysound/main/install.sh -o install.sh
less install.sh
bash install.sh
```

옵션: `--no-hooks`, `--skills-dir <경로>`(반복 가능), `--version <태그>`,
`--uninstall`.

### 설치 스크립트가 건드리는 것

| 경로                                                      | 하는 일                                       |
| --------------------------------------------------------- | --------------------------------------------- |
| `~/.local/share/notifysound`                              | 설치 트리 — 실행할 때마다 교체                |
| `~/.local/bin/notifysound`                                | CLI 심링크                                    |
| `~/.claude/hooks/notifysound-play.sh`                     | 재생기 심링크                                 |
| `~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills` | 각각에 심링크, **이미 존재하는 디렉터리에만** |
| `~/.claude/settings.json`                                 | `# notifysound` 서명이 붙은 `Stop` 훅 1개     |
| `~/.codex/hooks/notify.sh`                                | `# notifysound` 서명이 붙은 블록 1개          |

사용자의 음원과 설정이 있는 `~/.claude/notifysound/`는 절대 건드리지 않는다.
설치 스크립트를 다시 실행하는 것이 곧 업데이트다. `--uninstall`은 상태 디렉터리를
제외한 모든 것을 되돌리며, 그 디렉터리는 직접 지우도록 남겨 둔다.

없는 디렉터리는 새로 만들지 않는다 — Codex를 한 번도 쓴 적 없는 머신에 빈
`~/.codex/skills`가 생기지 않는다. 심링크가 아니라 실제 디렉터리가 있는 경로
(대개 `skills add` 복사본)는 지우지 않고 그대로 둔다.

## 사용법

```bash
notifysound list            # 등록된 음원
notifysound use crystal     # 교체
notifysound test            # 지금 들어보기
notifysound off --host codex   # Codex만 조용히, Claude Code는 그대로
notifysound status          # 무엇이 켜져 있고, 설치돼 있고, 연결돼 있는지
```

| 명령                                  | 하는 일                                            |
| ------------------------------------- | -------------------------------------------------- |
| `on` / `off` `[--host claude\|codex]` | 전역 스위치, 또는 호스트 하나                      |
| `reset --host claude\|codex`          | 호스트 오버라이드 해제, 전역값을 따름              |
| `status`                              | 상태·훅 건강도·재생기 건강도·스킬 링크 (읽기 전용) |
| `list`                                | 등록된 음원 (빌트인/사용자 구분)                   |
| `add <이름> <파일> [--force]`         | 파일을 라이브러리로 복사해 등록                    |
| `use <이름>`                          | 현재 음원 교체                                     |
| `remove <이름>`                       | 사용자 음원 등록 해제 및 파일 삭제                 |
| `test [이름]`                         | enabled 스위치를 무시하고 즉시 재생                |
| `install` / `uninstall`               | 호스트 훅 설치 또는 제거                           |

호스트별 상태는 두 번째 스위치가 아니라 **오버라이드**다. `null`이면 "전역을 따름"을
뜻한다. `off` 후 `reset --host codex`는 Codex를 켜는 것이 아니라 전역 통제로
되돌린다.

`add`는 참조가 아니라 복사한다. 파일이 `~/.claude/notifysound/sounds/`로 들어가므로,
이후 원본을 옮기거나 지워도 재생에 영향이 없다.

종료 코드: `0` 성공, `1` 사용자 오류, `2` 환경 오류.

## 빌트인 음원

`notifysound install`이 12종을 등록한다. 6종은 제자리에서 참조하는 macOS 시스템
사운드이고, 6종은 이 저장소에 번들된 CC0 파일이다.

|                  |                                                        |                                    |
| ---------------- | ------------------------------------------------------ | ---------------------------------- |
| **macOS**        | `glass` `ping` `hero` `pop` `submarine` `tink`         | `/System/Library/Sounds/`에서 참조 |
| **Kenney (CC0)** | `confirm` `bong` `pluck` `crystal` `question` `switch` | 번들, 각 0.11~0.34초               |

등록은 이미 쓰고 있는 이름을 덮어쓰지 않고, 현재 선택도 바꾸지 않는다. 빌트인은
삭제할 수 없다 — 설치 자산이라 다음 설치 때 되살아나기 때문이다. 대신
`add --force <이름>`으로 자기 파일로 덮어쓸 수 있고, 그 시점부터 그 이름은 평범한,
삭제 가능한 사용자 음원이 된다.

원본 Kenney 파일명과 선정 기준을 포함한 모든 파일의 출처는
[`sounds/CREDITS.md`](sounds/CREDITS.md)에 있다.

## 무엇이 어디에 있나

```
~/.local/share/notifysound/     설치 트리 (업데이트 시 교체)
  scripts/                      CLI, 재생기, 라이브러리
  sounds/                       빌트인 매니페스트와 번들 CC0 파일

~/.claude/notifysound/          사용자 상태 (설치가 절대 건드리지 않음)
  config.json                   스위치, 현재 음원, 등록된 음원
  sounds/                       직접 추가한 파일
```

`NOTIFYSOUND_HOME`으로 상태 디렉터리를 옮길 수 있다. 기본값이 `~/.claude/` 아래인 것은
이전 버전과의 호환 때문이며, 이 디렉터리에 Claude 고유의 성질은 없다. 향후 버전에서
`~/.local/state/notifysound/`로 옮길 수 있다.

재생기는 자기 심링크 체인을 따라가 라이브러리를 찾으므로 설치 위치가 코드 어디에도
박혀 있지 않다. 트리를 옮기고 심링크만 다시 걸어도 그대로 동작한다.

## 실패하는 방식

의도적으로, 조용히. config가 없거나, 깨졌거나, 꺼져 있거나, 더 이상 존재하지 않는
파일을 가리킬 때 `notifysound-play.sh`는 아무것도 출력하지 않고 exit 0으로 끝난다.
소리 문제가 에이전트 문제가 되는 일은 허용하지 않는다.

알아 둘 만한 두 가지 귀결이 있다.

- `uninstall`은 notifysound 이전에 있던 알림 훅을 복원하지 않는다. `# notifysound`
  서명이 붙은 것을 제거하고, 훅이 없는 상태로 끝난다.
- 반대로 `install`과 `uninstall`은 **오직** 서명된 항목만 건드린다. 직접 작성한
  `Stop` 훅이나 `agent-turn-complete` 블록은 양쪽 모두에서 한 바이트도 바뀌지 않고
  살아남는다.

`settings.json`이나 `notify.sh`를 수정할 때마다 원본 옆에 타임스탬프 백업
(`<파일>.notifysound-bak-<타임스탬프>-XXXXXX`)을 쓴다.

## 크레딧

번들 음원은 Kenney의 [Interface Sounds](https://kenney.nl/assets/interface-sounds)와
[UI Audio](https://kenney.nl/assets/ui-audio) 팩에서 가져왔으며 CC0 1.0으로
공개돼 있다.

## 라이선스

[MIT](./LICENSE) © Dante Labs

---

<div align="center">

**Dante Labs** · **YouTube** [@dante-labs](https://youtube.com/@dante-labs) · **Email** [dante@dante-labs.com](mailto:dante@dante-labs.com) · **Discord** [Dante Labs Community](https://discord.com/invite/rXyy5e9ujs) · **Support** [Buy Me a Coffee](https://buymeacoffee.com/dante.labs)

</div>
