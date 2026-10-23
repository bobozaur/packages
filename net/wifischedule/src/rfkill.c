// SPDX-License-Identifier: ISC
#include <stdio.h>
#include <string.h>
#include <uci.h>

int main(int argc, char **argv)
{
	struct uci_context *ctx;
	struct uci_package *package = NULL;
	struct uci_element *element;
	int result = 1;

	if (argc != 2 || (strcmp(argv[1], "0") && strcmp(argv[1], "1")))
		return 1;
	ctx = uci_alloc_context();
	if (!ctx)
		return 1;

	/* Absolute loads exclude other writers' deltas and runtime overrides.
	 * Reload after taking the canonical UCI lock so concurrent commits cannot
	 * be overwritten by the initial snapshot used to identify the file.
	 */
	if (uci_load(ctx, "/etc/config/wireless", &package) ||
	    uci_lock(ctx, package))
		goto out;
	uci_unload(ctx, package);
	package = NULL;
	if (uci_load(ctx, "/etc/config/wireless", &package))
		goto out;

	uci_foreach_element(&package->sections, element) {
		struct uci_section *section = uci_to_section(element);
		struct uci_ptr ptr = {
			.p = package,
			.s = section,
			.package = package->e.name,
			.section = section->e.name,
			.option = "disabled",
			.value = argv[1],
		};

		if (!strcmp(section->type, "wifi-device") && uci_set(ctx, &ptr))
			goto out;
	}
	if (!uci_commit(ctx, &package, true))
		result = 0;
out:
	if (result)
		uci_perror(ctx, "wifischedule");
	uci_free_context(ctx);
	return result;
}
