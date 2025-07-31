switcher_group_vi() {
	points=(bin/vi:libexec/busybox/vi)
	priority=10
}

switcher_group_editor() {
	points=(bin/editor:libexec/busybox/vi)
	priority=10
}

switcher_group_pager() {
	points=(bin/pager:libexec/busybox/less)
	priority=10
}

switcher_group_nc() {
	points=(bin/nc:libexec/busybox/nc
		bin/ncat:libexec/busybox/nc
		bin/netcat:libexec/busybox/nc
	)
	priority=10
}
