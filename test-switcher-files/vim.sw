switcher_group_vim() {
	associations=(bin/vim:libexec/vim/vim)
	priority=50
}

switcher_group_ex() {
	associations=(bin/ex:libexec/vim/ex)
	priority=50
}

switcher_group_view() {
	associations=(bin/view:libexec/vim/view)
	priority=50
}

switcher_group_vimdiff() {
	associations=(bin/vimdiff:libexec/vim/vimdiff)
	priority=50
}

switcher_group_vimtutor() {
	associations=(bin/vimtutor:libexec/vim/vimtutor)
	priority=50
}

switcher_group_editor() {
	associations=(bin/editor:bin/vim
		share/man/man1/editor.1.gz:share/man/man1/vim.1.gz)
	priority=50
}

switcher_group_vi() {
	associations=(bin/vi:bin/vim
		share/man/man1/vi.1.gz:share/man/man1/vim.1.gz)
	priority=30
}
