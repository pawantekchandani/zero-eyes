const { Command, Plugin } = require("@opencode/plugin/gui")

/**
 * Desktop-app part of Zero Eyes.
 *
 * Ctrl+Shift+R starts reading the last answer and the same key stops it.
 * Ctrl+Alt+Z reads the text selected in the window, matching the macOS
 * macOS Services read (Control+Option+Z); OpenCode has no Services menu, so it
 * needs this binding.
 * The palette also has an explicit "Stop reading aloud" command for speech
 * that auto-play started when an answer finished.
 *
 * Both commands call the server part, which owns the speech process, so the
 * key, the palette, and the slash commands share one state.
 *
 * No build step: this file is plain CommonJS and requires only the module the
 * desktop app provides.
 */
module.exports = Plugin.define({
  i18n: {
    en: {
      "command.toggle": "Read last response aloud",
      "command.toggle.description": "Start or stop reading the last answer aloud",
      "command.stop": "Stop reading aloud",
      "command.stop.description": "Stop speech, including auto-play of a finished answer",
      "command.selection": "Read selected text aloud",
      "command.selection.description": "Speak the text currently selected in this window",
      "command.group": "Read aloud",
    },
  },
  setup(ctx) {
    const run = (name, failure) => {
      const session = ctx.sessions.current()
      if (!session) return
      void ctx.client.session
        .command({ sessionID: session.id, name, text: "" })
        .catch((cause) => {
          ctx.toast.show({
            message: `${failure}: ${cause instanceof Error ? cause.message : String(cause)}`,
            variant: "warning",
          })
        })
    }

    const selectionText = () => {
      try {
        const selection = typeof window === "undefined" ? null : window.getSelection()
        return selection ? selection.toString().trim() : ""
      } catch {
        return ""
      }
    }

    ctx.add(Command, () => ({
      id: "toggle",
      title: ctx.t("command.toggle"),
      description: ctx.t("command.toggle.description"),
      keywords: "read aloud speech speak stop voice",
      group: ctx.t("command.group"),
      section: "session",
      bind: "ctrl+shift+r",
      enabled: !!ctx.sessions.current(),
      run: () => run(ctx.options.name ?? "zero-eyes", "Zero Eyes failed"),
    }))

    ctx.add(Command, () => ({
      id: "stop",
      title: ctx.t("command.stop"),
      description: ctx.t("command.stop.description"),
      keywords: "stop silence quiet speech voice",
      group: ctx.t("command.group"),
      section: "session",
      enabled: !!ctx.sessions.current(),
      run: () => run("zero-eyes-stop", "Stop reading failed"),
    }))

    ctx.add(Command, () => ({
      id: "selection",
      title: ctx.t("command.selection"),
      description: ctx.t("command.selection.description"),
      keywords: "read aloud speech speak selection selected text",
      group: ctx.t("command.group"),
      section: "session",
      bind: "ctrl+alt+z",
      editable: true,
      enabled: !!ctx.sessions.current(),
      run: () => {
        const session = ctx.sessions.current()
        if (!session) return
        const text = selectionText()
        if (!text) {
          ctx.toast.show({ message: "Select some text first.", variant: "warning" })
          return
        }
        void ctx.client.session
          .command({ sessionID: session.id, name: ctx.options.name ?? "zero-eyes", text })
          .catch((cause) => {
            ctx.toast.show({
              message: `Read selection failed: ${cause instanceof Error ? cause.message : String(cause)}`,
              variant: "warning",
            })
          })
      },
    }))
  },
})
