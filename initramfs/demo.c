#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>

static void rule(const char *title)
{
	printf("\n== %s ==\n", title);
}

int main(void)
{
	struct utsname u;
	struct timespec t0, t1;
	char line[256];
	FILE *f;
	pid_t kid;
	long ms;
	int status;
	volatile char *page;

	printf("ELF demo: pid %d\n", (int)getpid());

	rule("uname");
	if (uname(&u) == 0) {
	  printf("%s %s %s\n", u.sysname, u.release, u.machine);
	}

	rule("this process's memory map");
	f = fopen("/proc/self/maps", "r");
	if (f) {
		while (fgets(line, sizeof line, f)) {
			fputs(line, stdout);
		}
		fclose(f);
	} else {
		printf("(no /proc ?)\n");
	}

	rule("demand paging");
	page = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (page == MAP_FAILED) {
		printf("mmap failed\n");
	} else {
		page[0] = 42;
		page[4095] = 43;
		printf("mapped a page at %p, wrote and read back %d/%d\n", (void *)page, page[0], page[4095]);
		munmap((void *)page, 4096);
	}

	rule("fork");
	kid = fork();
	if (kid == 0) {
		printf("child: pid %d, parent %d\n", (int)getpid(), (int)getppid());
		_exit(7);
	} else if (kid > 0) {
		waitpid(kid, &status, 0);
		printf("parent: pid %d, child %d exited with %d\n", (int)getpid(), (int)kid, WEXITSTATUS(status));
	}

	rule("timer from userspace");
	clock_gettime(CLOCK_MONOTONIC, &t0);
	sleep(1);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
	printf("slept 1s, clock says %ld ms\n", ms);

	rule("demo end");
	return 0;
}
