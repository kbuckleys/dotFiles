# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/

# Powerlevel10k init
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

if [[ -f "/opt/homebrew/bin/brew" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Set the directory where zinit and plugins will be stored
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Sync Zinit, if it isn't
if [ ! -d "$ZINIT_HOME" ]; then
   mkdir -p "$(dirname $ZINIT_HOME)"
   git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

# Source/Load zinit
source "${ZINIT_HOME}/zinit.zsh"

# Add in Powerlevel10k
zinit ice depth=1; zinit light romkatv/powerlevel10k

# Add in zsh plugins
# NOTE: zsh-vi-mode is added here to enable Vim motions
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-completions
zinit light Aloxaf/fzf-tab
zinit light jeffreytse/zsh-vi-mode
# Must stay last: zsh-syntax-highlighting wraps the ZLE widgets that exist when
# it is sourced, so anything loaded after it goes unhighlighted.
zinit light zsh-users/zsh-syntax-highlighting

# zsh-vi-mode defaults to the *steady* cursor shapes (\e[6 q insert, \e[2 q
# normal). A steady DECSCUSR overrides kitty's cursor_blink_interval, which is
# what suppresses the pulse; the blinking variants hand the rhythm back to the
# terminal. Set here rather than in zvm_after_init so the very first prompt
# already has it.
ZVM_INSERT_MODE_CURSOR=$ZVM_CURSOR_BLINKING_BEAM
ZVM_NORMAL_MODE_CURSOR=$ZVM_CURSOR_BLINKING_BLOCK

# Add in snippets
zinit snippet OMZP::command-not-found
zinit snippet OMZP::archlinux
zinit snippet OMZL::git.zsh
zinit snippet OMZP::kubectl
zinit snippet OMZP::kubectx
zinit snippet OMZP::sudo
zinit snippet OMZP::git
zinit snippet OMZP::aws

# 1. Load completions system (MUST be before cdreplay)
autoload -Uz compinit && compinit

# 2. Replay intercepted compdef calls (MUST be after compinit)
zinit cdreplay -q

# 3. Powerlevel10k config (Must be after plugins)
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# History
HISTFILE=~/.zsh_history
HISTSIZE=5000
SAVEHIST=5000
setopt appendhistory
setopt sharehistory
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt hist_save_no_dups
setopt hist_find_no_dups

# Completion styling
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color=always $realpath'
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color=always $realpath'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' menu no
setopt glob_dots

export FZF_DEFAULT_OPTS='
  --color=fg+:#dfdfdd,bg+:#20242a,pointer:#e0d8a4,marker:#fab387,hl+:#b6e0a4,hl::#b6e0a4,spinner:#9bbfbf,border:#20242a,info:#eebebe
  --border=top
'

# Aliases
alias hypr='start-hyprland'
alias ls='eza -G --icons'
alias icat='kitten icat'

# Shell integrations
eval "$(zoxide init --cmd cd zsh)"
eval "$(fzf --zsh)"

function zvm_after_init() {
  bindkey -M viins '^H' fzf-history-widget
  bindkey -M vicmd '^R' redo
  bindkey -M viins '^T' fzf-file-widget
  bindkey -M viins '\ec' fzf-cd-widget

  # Vi mode unbinds these on init. It initialises from a precmd, i.e. after
  # .zshrc has finished, so binding them at top level does not survive — they
  # have to be (re)bound here.
  bindkey '^p' history-search-backward
  bindkey '^n' history-search-forward
  bindkey '^[w' kill-region

  export ZVM_VI_HIGHLIGHT_BACKGROUND=#c8a4e0
  export ZVM_VI_HIGHLIGHT_FOREGROUND=#000000
  export ZVM_VI_HIGHLIGHT_EXTRASTYLE=bold
  
  zvm_highlight update
}

# NOTE: cwd reporting (OSC-7) used to be hand-rolled here for foot. kitty's
# shell integration registers _ksi_report_pwd on chpwd and every prompt unless
# shell_integration is set to no-cwd, so it is handled. If a terminal without
# shell integration ever comes back, this is what needs restoring.
