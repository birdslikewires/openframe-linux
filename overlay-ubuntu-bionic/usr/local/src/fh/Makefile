#
# fh/Makefile
#
# Build the firmware hub driver
#

MOD = fh

PWD := $(shell pwd)
KDIR := /lib/modules/$(shell uname -r)/build

obj-m += $(MOD).o

default:
	        $(MAKE) -C $(KDIR) M=$(PWD) modules

install:
		$(MAKE) -C $(KDIR) M=$(PWD) modules_install
		depmod -a

clean:
	rm -f .fh.ko.cmd .fh.mod.o.cmd .fh.o.cmd Module.symvers fh.ko fh.mod.c fh.mod.o fh.o
	rm -rf .tmp_versions modules.order
