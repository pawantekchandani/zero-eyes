import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { Plugin } from "@opencode/plugin"

/**
 * Read answers aloud, from any client.
 *
 * Registers server-side commands (any client, including the desktop app) and,
 * unless `auto: false`, speaks each answer when its turn completes.
 *
 * Uses the OS speech engine on the machine running the server:
 *   macOS   -> ~/.local/bin/zero-eyes (the Zero Eyes player: Edge TTS voices,
 *              fallback to say; voice and rate in ~/.config/zero-eyes/config)
 *              when present, else say
 *   Linux   -> ~/.local/bin/zero-eyes when present (piper or espeak-ng),
 *              else spd-say
 *   Windows -> PowerShell + System.Speech
 *
 * Commands:
 *   /zero-eyes           latest answer, or stop it if it is speaking
 *   /zero-eyes older     one answer further back (repeat to keep going)
 *   /zero-eyes 3         third-newest answer
 *   /zero-eyes list      spoken list of the recent answers
 *   /zero-eyes-stop      stop speaking
 *
 * The desktop GUI binds Ctrl+Shift+R to the same start/stop toggle.
 *
 * On macOS and Linux the shared player keeps a capped queue: a new answer waits behind
 * whatever is speaking, and only the newest three may wait, so answers do not
 * go stale. /zero-eyes-stop clears the queue for every app using that player,
 * not just this one.
 */

type Options = {
  /** Voice name, e.g. "Samantha" on macOS. */
  voice?: string
  /** Words per minute (macOS `say -r`). */
  rate?: number
  /** Override the binary used for speech. */
  command?: string
  /** Override the arguments for the binary. Text is always piped to stdin. */
  args?: string[]
  /** Command name shown in the client, without the leading slash. */
  name?: string
  /** App name shown at the start of the overlay's first line. Defaults to "OpenCode". */
  origin?: string
  /** Speak each finished answer automatically. Defaults to true. */
  auto?: boolean
}

type ContentPart = { type?: string; text?: string }
type Message = {
  id?: string
  type?: string
  finish?: string
  time?: { created?: number; completed?: number }
  content?: ContentPart[]
}

type Answer = { id: string; text: string; created?: number }

type Speech = ReturnType<typeof spawn>

/**
 * OpenCode can evaluate this plugin more than once in the same process. Keep
 * the speech set and the auto-play memo on globalThis so every copy shares
 * them: one answer is spoken once, and stop kills every copy's child.
 */
type ReadAloudState = {
  speaking: Set<Speech>
  autoSpoken: Map<string, string>
  cursors: Map<string, number>
}

const STATE_KEY = "__opencodeReadAloudState"
const state: ReadAloudState = ((globalThis as any)[STATE_KEY] ??= {
  speaking: new Set<Speech>(),
  autoSpoken: new Map<string, string>(),
  cursors: new Map<string, number>(),
})
const { speaking, autoSpoken, cursors } = state

function toSpeech(markdown: string): string {
  return markdown
    .replace(/```[\s\S]*?```/g, " Code block. ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/\bhttps?:\/\/\S+/g, " link ")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/^\s{0,3}>\s?/gm, "")
    .replace(/^\s*[-*+]\s+/gm, "")
    .replace(/\|/g, " ")
    .replace(/[*_~]{1,3}/g, "")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
}

/**
 * Assistant answers, newest first. A turn also contains assistant messages
 * that only call tools (and short "let me check" notes before them), so keep
 * only messages that finished a turn with text, falling back to any text when
 * no finish value is present.
 */
function answers(messages: readonly Message[]): Answer[] {
  const finals: Answer[] = []
  const loose: Answer[] = []

  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i]
    if (message?.type !== "assistant") continue
    const parts = Array.isArray(message.content) ? message.content : []
    const text = parts
      .filter((part) => part?.type === "text" && typeof part.text === "string")
      .map((part) => part.text!)
      .join("\n\n")
    if (!text.trim()) continue

    const answer = { id: message.id ?? `message-${i}`, text, created: message.time?.created }
    loose.push(answer)
    if (message.finish !== "tool-calls" && message.finish !== "content-filter") finals.push(answer)
  }

  return finals.length > 0 ? finals : loose
}

function relative(timestamp: number): string {
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000))
  if (seconds < 90) return "just now"
  const minutes = Math.round(seconds / 60)
  if (minutes < 90) return `${minutes} minutes ago`
  const hours = Math.round(minutes / 60)
  if (hours < 36) return `${hours} hours ago`
  return `${Math.round(hours / 24)} days ago`
}

function listText(answers: readonly Answer[]): string {
  return answers
    .slice(0, 10)
    .map((answer, index) => {
      const preview = toSpeech(answer.text).replace(/\s+/g, " ").trim().slice(0, 90)
      const when = answer.created ? `, ${relative(answer.created)}` : ""
      return `Answer ${index + 1}${when}: ${preview}`
    })
    .join("\n")
}

/** The Zero Eyes player; it owns the voice, rate and queue. */
const PLAYER = join(homedir(), ".local/bin/zero-eyes")

function zeroEyes(): string | null {
  // The player runs on macOS and Linux only, so never elsewhere.
  return (process.platform === "darwin" || process.platform === "linux") && existsSync(PLAYER)
    ? PLAYER
    : null
}

function speak(text: string, options: Options): boolean {
  const body = toSpeech(text)
  if (!body) return false

  const isMac = process.platform === "darwin"
  const isWindows = process.platform === "win32"
  const player = zeroEyes()

  // The Edge wrapper queues, so leave whatever is speaking alone. Other
  // engines have no queue and would talk over each other, so stop the last one.
  if (!player) stopSpeaking()

  const command = options.command ?? player ?? (isMac ? "say" : isWindows ? "powershell" : "spd-say")
  const args =
    options.args ??
    (player
      ? ["--queue"] // text goes to stdin; the shared player appends it
      : isMac
        ? [
            ...(options.voice ? ["-v", options.voice] : []),
            ...(options.rate ? ["-r", String(options.rate)] : []),
          ]
        : isWindows
          ? [
              "-NoProfile",
              "-Command",
              "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.Speak([Console]::In.ReadToEnd())",
            ]
          : [])

  const child = spawn(command, args, {
    stdio: ["pipe", "ignore", "ignore"],
    // Speak under the app's name in the shared overlay, not the server's.
    env: { ...process.env, ZERO_EYES_ORIGIN: options.origin ?? "OpenCode" },
  })
  speaking.add(child)
  child.on("error", () => {
    speaking.delete(child)
  })
  child.on("close", () => {
    speaking.delete(child)
  })
  child.stdout?.on("error", () => {})
  child.stdin?.on("error", () => {})
  child.stdin?.end(body)
  return true
}

function stopSpeaking(): void {
  const children = [...speaking]
  speaking.clear()

  // The Edge wrapper is the parent of afplay: SIGKILL would kill the wrapper
  // only and leave the audio playing. SIGTERM lets it kill afplay and remove
  // its pid files; anything that ignores it is forced after a short grace.
  for (const child of children) {
    try {
      child.kill("SIGTERM")
    } catch {}
  }
  if (children.length > 0) {
    setTimeout(() => {
      for (const child of children) {
        if (child.exitCode === null) {
          try {
            child.kill("SIGKILL")
          } catch {}
        }
      }
    }, 500)
  }

  // Queued speech is owned by the shared player, not by a child we hold, so
  // ask it to drop the backlog and the worker too. This stops every app using
  // that player, which is what a single Stop key should do.
  const player = zeroEyes()
  if (!player) return
  try {
    const stopper = spawn(player, ["--stop"], { stdio: "ignore", detached: true })
    stopper.on("error", () => {})
    stopper.unref()
  } catch {}
}

/** True when the shared player is speaking or has items still waiting. */
function wrapperBusy(): Promise<boolean> {
  const player = zeroEyes()
  if (!player) return Promise.resolve(false)
  return new Promise((resolve) => {
    try {
      const probe = spawn(player, ["--status"], { stdio: "ignore" })
      probe.on("error", () => resolve(false))
      probe.on("close", (code) => resolve(code === 0))
    } catch {
      resolve(false)
    }
  })
}

export default Plugin.define({
  id: "zero-eyes",
  async setup(ctx) {
    const options = (ctx.options ?? {}) as Options

    await ctx.command.transform((editor) => {
      editor.add({
        name: options.name ?? "zero-eyes",
        description: "Read an answer aloud: latest, 'older', a number, 'list', or any other text",
        execute: async ({ sessionID, prompt }) => {
          const argument = (prompt?.text ?? "").trim()

          // No argument toggles: stop anything that is speaking, even when the
          // session in view has no answers yet (for example speech that
          // auto-play started in another session), otherwise read the latest.
          if (!argument && (speaking.size > 0 || (await wrapperBusy()))) {
            stopSpeaking()
            return
          }

          // Any argument that is not a position keyword is the text itself.
          // The desktop selection command passes the selected text this way.
          if (argument && !/^(list|older|prev|previous|back|\d+)$/i.test(argument)) {
            speak(argument, options)
            return
          }

          const found = answers((await ctx.session.context({ sessionID })) as readonly Message[])
          if (found.length === 0) return

          if (/^list$/i.test(argument)) {
            speak(listText(found), options)
            return
          }

          let index = 0
          if (/^(older|prev|previous|back)$/i.test(argument)) {
            index = (cursors.get(sessionID) ?? 0) + 1
          } else if (/^\d+$/.test(argument)) {
            index = Math.max(0, Number.parseInt(argument, 10) - 1)
          }

          if (index >= found.length) {
            speak("There are no older answers in this session.", options)
            return
          }

          const answer = found[index]
          cursors.set(sessionID, index)
          autoSpoken.set(sessionID, answer.id)
          speak(answer.text, options)
        },
      })

      editor.add({
        name: "zero-eyes-stop",
        description: "Stop reading aloud",
        execute: async () => {
          stopSpeaking()
        },
      })
    })

    if (options.auto === false) return

    const controller = new AbortController()

    const speakLatest = async (sessionID: string) => {
      const session = await ctx.session.get({ sessionID })
      // Subagent sessions would otherwise narrate their own side work.
      if (session.parentID) return

      const found = answers((await ctx.session.context({ sessionID })) as readonly Message[])
      if (found.length === 0) return

      const latest = found[0]
      if (autoSpoken.get(sessionID) === latest.id) return

      autoSpoken.set(sessionID, latest.id)
      if (speak(latest.text, options)) {
        console.log(`zero-eyes: speaking ${latest.id} of ${sessionID}`)
      }
    }

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({
          types: ["session.execution.succeeded"],
          signal: controller.signal,
        })) {
          // Public events carry their payload under `data`.
          const sessionID =
            (event as { data?: { sessionID?: string } }).data?.sessionID ??
            (event as { sessionID?: string }).sessionID
          if (!sessionID) continue
          void speakLatest(sessionID).catch(() => {})
        }
      } catch {
        // An aborted stream is how the plugin unloads.
      }
    })()

    return () => controller.abort()
  },
})
