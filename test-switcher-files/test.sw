# example switcher
switcher_group_test-switcher() {
	associations=(bin/test-switcher:bin/test
		share/man/man1/test-switcher.1.gz:share/man/man1/test.1.gz
	)
	priority=100
}

switcher_group_test-switcher2() {
	associations=(bin/test-switcher2:bin/test
		share/man/man1/test-switcher2.1.gz:share/man/man1/test.1.gz
	)
	priority=100
}
