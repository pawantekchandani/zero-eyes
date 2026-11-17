#!/bin/sh
# Any harness can speak through Zero Eyes: pipe it the text.
# The player queues it, shows the overlay, and names the app it thinks the
# speech came from.

printf '%s' "Zero Eyes read this text aloud." | ~/.local/bin/zero-eyes

# Name the app yourself — that is what the overlay's first line shows:
printf '%s' "Named origin." | ZERO_EYES_ORIGIN="My Tool" ~/.local/bin/zero-eyes
