switcher_group_vim() {
	points=(bin/vim:libexec/vim/vim)
	priority=50
}

switcher_group_ex() {
	points=(bin/ex:libexec/vim/ex)
	priority=50
}

switcher_group_view() {
	points=(bin/view:libexec/vim/view)
	priority=50
}

switcher_group_vimdiff() {
	points=(bin/vimdiff:libexec/vim/vimdiff)
	priority=50
}

switcher_group_vimtutor() {
	points=(bin/vimtutor:libexec/vim/vimtutor)
	priority=50
}

switcher_group_editor() {
	points=(bin/editor:bin/vim
		share/man/man1/editor.1.gz:share/man/man1/vim.1.gz)
	priority=50
}

switcher_group_vi() {
	points=(bin/vi:bin/vim
		share/man/man1/vi.1.gz:share/man/man1/vim.1.gz)
	priority=30
}
