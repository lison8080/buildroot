# root 的全局环境（Buildroot 版本：zsh 在 /usr/bin，函数库在 /usr/share/zsh）
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export TERMINFO_DIRS=/usr/share/terminfo

# oh-my-zsh 在受限 shell 下需要显式 fpath（Buildroot 的 zsh-common 函数库布局）
if [ -d /usr/share/zsh/site-functions ]; then
    fpath=(/usr/share/zsh/site-functions $fpath)
fi
