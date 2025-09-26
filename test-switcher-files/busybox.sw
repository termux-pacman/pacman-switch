switcher_group_vi() {
	associations=(bin/vi:libexec/busybox/vi)
	priority=10
}

switcher_group_editor() {
	associations=(bin/editor:libexec/busybox/vi)
	priority=10
}

switcher_group_pager() {
	associations=(bin/pager:libexec/busybox/less)
	priority=10
}

switcher_group_nc() {
	associations=(bin/nc:libexec/busybox/nc
		bin/ncat:libexec/busybox/nc
		bin/netcat:libexec/busybox/nc
	)
	priority=10
}
