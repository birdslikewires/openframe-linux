/*
 * fh.c
 *
 * Firmware Hub driver
 *
 * "Firmware Hub" is Intel's new name for the
 * EPROM that stores the BIOS.  The OpenFrame
 * uses:
 *
 * Intel E82802AC8
 * SST   49LF008A
 */

#include <linux/delay.h>
#include <linux/slab.h>

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>

#include <linux/semaphore.h>
#include <linux/uaccess.h>
#include <linux/io.h>

#define FH_DATA_PHYS		0xFFF00000
#define FH_DATA_SIZE		0x00100000

#define FH_LOCK_PHYS		0xFFB00000
#define FH_LOCK_SIZE		0x00100000

#define FH_BLOCK_SIZE		0x00010000
#define FH_BLOCK_MASK		((FH_BLOCK_SIZE) - 1)

/* Give up rather than spin forever if the chip never reports done */
#define FH_ERASE_POLLS		67	/* x 150 ms, about 10 s (Intel) */
#define FH_SST_ERASE_POLLS	200	/* x 5 ms, about 1 s (SST) */
#define FH_PROGRAM_POLLS	10000	/* x 1 us, about 10 ms per byte */

static struct {
	int major;
	int users;
	struct semaphore sem;
	struct class *class;
	unsigned long size;	/* Size of the device (1MB) */
	void *vdata;		/* Fwhub data blocks (kernel virtual) */
	void *vlock;		/* Fwhub block lock controls (kernel virtual) */
	int mfr_id;		/* Manufacturer identifier */
	int dev_id;		/* Device type identifier */
	void *buffer;		/* Buffer 1 block for writes */

	int (*lock)(unsigned long baddr);
	int (*unlock)(unsigned long baddr);
	int (*erase)(unsigned long baddr);
	int (*program)(unsigned long baddr, unsigned char *buffer);
} fh = {
	.size	= 0x00100000,
};

static int	fh_open(struct inode *inode, struct file *file);
static int	fh_release(struct inode *inode, struct file *file);
static ssize_t	fh_write(struct file *filp, const char __user *buf, size_t count, loff_t *f_pos);
static ssize_t	fh_read(struct file *filp, char __user *buf, size_t count, loff_t *f_pos);

/* Allow seeking anywhere within the 1 MB device, so dd seek= and skip= work */
static loff_t fh_llseek(struct file *filp, loff_t offset, int whence)
{
	return fixed_size_llseek(filp, offset, whence, fh.size);
}

static struct file_operations fh_fops = {
	.owner		= THIS_MODULE,
	.llseek		= fh_llseek,
	.open		= fh_open,
	.release	= fh_release,
	.write		= fh_write,
	.read		= fh_read,
};

static struct miscdevice fh_dev = {
        .minor          = MISC_DYNAMIC_MINOR,
        .name           = "fh",
        .fops           = &fh_fops,
};

/*
 * Unlock a block in the firmware hub so that it can be programmed.
 * This function works for both Intel and SST chips.
 */
static int fwhub_unlock(unsigned long baddr)
{
	volatile unsigned char *lock_addr = (volatile unsigned char *)(fh.vlock + baddr + 2);
	unsigned int lock_data;

	*lock_addr = 0x00;
	lock_data = *lock_addr;
	if (lock_data != 0x00) {
		printk("fh: fwhub_unlock error baddr=0x%08lx lock=0x%02x\n", baddr, lock_data);
		return -EIO;
	}
	return 0;
}

/*
 * Lock a block in the firmware hub so that it can not be programmed.
 * This function works for both Intel and SST chips.
 */
static int fwhub_lock(unsigned long baddr)
{
	volatile unsigned char *lock_addr = (volatile unsigned char *)(fh.vlock + baddr + 2);
	unsigned int lock_data;

	*lock_addr = 0x01;
	lock_data = *lock_addr;
	if (lock_data != 0x01) {
		printk("fh: fwhub_lock error baddr=0x%08lx lock=0x%02x\n", baddr, lock_data);
		return -EIO;
	}
	return 0;
}

static int i82802_present(void)
{
	volatile unsigned char *lpc_mem = (volatile unsigned char *)fh.vdata;
	volatile unsigned char *fwhub = (volatile unsigned char *)fh.vdata;
	int present;

	lpc_mem[0] = 0x90;		/* Read Identifier Codes Command */
	fh.mfr_id = lpc_mem[0];
	fh.dev_id = lpc_mem[1];

	fwhub[0] = 0xFF;		/* Read array command */

	present = fh.mfr_id == 0x89 && fh.dev_id == 0xAC;
	if (present) {
		printk("fh: Intel 82802AC Firmware Hub detected\n");
	}
	return present;
}

static int i82802_erase(unsigned long baddr)
{
	volatile unsigned char *fwhub = (volatile unsigned char *)fh.vdata;
	unsigned int status;
	int polls = 0;

	fwhub[0] = 0x50;		/* Clear status register */
	fwhub[baddr] = 0x20;		/* Block erase */
	fwhub[baddr] = 0xD0;		/* Block erase confirm */
	do {	/* About 130 msec */
		msleep(150);
		fwhub[0] = 0x70;	/* Read status register command */
		status = fwhub[0];	/* Read status register value */
	} while ((status & (1<<7)) == 0 && ++polls < FH_ERASE_POLLS);
	if ((status & (1<<7)) == 0) {
		printk("fh: i82802_erase timeout baddr=0x%08lx status=0x%02x\n", baddr, status);
		fwhub[0] = 0xFF;	/* Read array command */
		return -ETIMEDOUT;
	}
	if (status & 0x7f) {
		printk("fh: i82802_erase error, status=0x%02x\n", status);
		fwhub[0] = 0xFF;	/* Read array command */
		return -EIO;
	}
	fwhub[0] = 0xFF;		/* Read array command */
	return 0;
}

static int i82802_program(unsigned long baddr, unsigned char *buffer)
{
	volatile unsigned char *fwhub = (volatile unsigned char *)fh.vdata;
	unsigned int status;
	unsigned int boffs;
	int polls;

	for (boffs = 0; boffs < FH_BLOCK_SIZE; boffs++) {
		/*
		 * Erasing a block in the flash sets all the bytes in
		 * the block to the value 0xff, so we don't need to
		 * program data bytes that have that value.
		 */
		if (buffer[boffs] == 0xff) {
			continue;
		}
		fwhub[0] = 0x50;		/* Clear status register */
		fwhub[baddr + boffs] = 0x40;	/* Program command */
		fwhub[baddr + boffs] = buffer[boffs];
		for (polls = 0; ; polls++) {	/* About 3 or 4 usec for Intel */
			fwhub[0] = 0x70;	/* Read status register command */
			status = fwhub[0];	/* Read status register value */
			if ((status & (1<<7)) || polls >= FH_PROGRAM_POLLS)
				break;
			udelay(1);
		}
		if ((status & (1<<7)) == 0) {
			printk("fh: i82802_program timeout at 0x%08lx status=0x%02x\n", baddr + boffs, status);
			fwhub[0] = 0xFF;	/* Read array command */
			return -ETIMEDOUT;
		}
		if (status & 0x7f) {
			printk("fh: i82802_program error at 0x%08lx, status=0x%02x\n", baddr + boffs, status);
			fwhub[0] = 0xFF;	/* Read array command */
			return -EIO;
		}
	}
	fwhub[0] = 0xFF;			/* Read Array Command */
	return 0;
}

static int sst4900_present(void)
{
	volatile unsigned char *lpc_mem = (volatile unsigned char *)fh.vlock;
	int present;

	fh.mfr_id = lpc_mem[0x000C0000];
	fh.dev_id = lpc_mem[0x000C0001];

	present = fh.mfr_id == 0xBF && fh.dev_id == 0x5A;
	if (present) {
		printk("fh: SST4900LF008 Firmware Hub detected\n");
	}
	return present;
}

static int sst4900_erase(unsigned long baddr)
{
	volatile unsigned char *fwhub = (volatile unsigned char *)fh.vdata;
	int polls = 0;

	fwhub[0x5555] = 0xAA;
	fwhub[0x2AAA] = 0x55;
	fwhub[0x5555] = 0x80;
	fwhub[0x5555] = 0xAA;
	fwhub[0x2AAA] = 0x55;
	fwhub[baddr]  = 0x50;

	/*
	 * Flash data bit 7 is 0 while erase is active.  It reads as 1
	 * when the erase operation has completed.  Block erase is 25 msec
	 * at most, so give up after about 1 second.
	 */
	while ((fwhub[baddr] & (1<<7)) == 0) {
		if (++polls >= FH_SST_ERASE_POLLS) {
			printk("fh: sst4900_erase timeout baddr=0x%08lx\n", baddr);
			return -ETIMEDOUT;
		}
		mdelay(5);
	}
	return 0;
}

static int sst4900_program(unsigned long baddr, unsigned char *buffer)
{
	volatile unsigned char *fwhub = (volatile unsigned char *)fh.vdata;
	unsigned int boffs;
	int polls;

	for (boffs = 0; boffs < FH_BLOCK_SIZE; boffs++) {
		/*
		 * Erasing a block in the flash sets all the bytes in
		 * the block to the value 0xff, so we don't need to
		 * program data bytes that have that value.
		 */
		if (buffer[boffs] == 0xff) {
			continue;
		}
		fwhub[0x5555] = 0xAA;
		fwhub[0x2AAA] = 0x55;
		fwhub[0x5555] = 0xA0;
		fwhub[baddr + boffs] = buffer[boffs];

		/*
		 * When programming is active, bit 7 of the flash data reads as the
		 * complement of bit 7 in the data written.  When programming is
		 * completed, bit 7 of the flash data is the same value as bit 7
		 * of the programmed byte.  Byte program is 20 usec at most.
		 */
		polls = 0;
		while ((fwhub[baddr + boffs] & (1<<7)) != (buffer[boffs] & (1<<7))) {
			if (++polls >= FH_PROGRAM_POLLS) {
				printk("fh: sst4900_program timeout at 0x%08lx\n", baddr + boffs);
				return -ETIMEDOUT;
			}
			udelay(1);
		}
	}
	return 0;
}

static int fh_open(struct inode *inode, struct file *file)
{
	int ret = -EIO;

	if (down_interruptible(&fh.sem)) {
		return -ERESTARTSYS;
	}
	/*
	 * Check for an existing user before touching fh.buffer, which
	 * belongs to that user while the device is open.
	 */
	if (fh.users > 0) {
		ret = -EBUSY;
		goto out;
	}
	if ((fh.buffer = kmalloc(FH_BLOCK_SIZE, GFP_KERNEL)) == NULL) {
		printk("fh_open: kmalloc fails\n");
		ret = -ENOMEM;
		goto out;
	}
	fh.users++;
	ret = 0;

  out:
	up(&fh.sem);
	return ret;
}

static int fh_release(struct inode *inode, struct file *file)
{
	if (down_interruptible(&fh.sem)) {
		return -ERESTARTSYS;
	}
	if (fh.buffer != NULL) {
		kfree(fh.buffer);
		fh.buffer = NULL;
	}
	if (fh.users > 0) {
		fh.users--;
	}
	up(&fh.sem);

	return 0;
}

/*
 * Writes must start on a 64 KB block boundary and cover whole blocks,
 * because each block is erased before it is programmed.  Blocks whose
 * contents already match are left alone, so rewriting a full image only
 * erases the blocks that change.
 *
 * The file position advances by each block written, including on a
 * failure part way through, so it always reflects what reached the chip.
 */
static ssize_t fh_write(struct file *filp, const char __user *buf, size_t count, loff_t *f_pos)
{
	unsigned long foffs;
	unsigned long baddr;	/* Offset of block from start of flash */
	ssize_t ret;

	if (*f_pos < 0 || *f_pos >= fh.size) {
		return count ? -ENOSPC : 0;
	}
	foffs = (unsigned long)*f_pos;
	if (foffs & FH_BLOCK_MASK) {
		printk("fh: file offset 0x%08lx not block aligned\n", foffs);
		return -EINVAL;
	}
	if (count & FH_BLOCK_MASK) {
		printk("fh: write of 0x%zx bytes is not whole blocks\n", count);
		return -EINVAL;
	}
	if (count > fh.size - foffs) {
		printk("fh: write too big (offset=0x%08lx, count=0x%zx)\n", foffs, count);
		return -EINVAL;
	}

	if (down_interruptible(&fh.sem)) {
		return -ERESTARTSYS;
	}
	for (baddr = foffs; baddr < (foffs + count); baddr += FH_BLOCK_SIZE) {
		if (copy_from_user(fh.buffer, buf, FH_BLOCK_SIZE)) {
			ret = -EFAULT;
			goto out;
		}
		buf += FH_BLOCK_SIZE;

		if (!memcmp((char *)fh.vdata + baddr, fh.buffer, FH_BLOCK_SIZE)) {
			printk("fh: block 0x%08lx unchanged, skipped\n", baddr);
			*f_pos = baddr + FH_BLOCK_SIZE;
			continue;
		}

		if ((ret = fh.unlock(baddr)) < 0) goto out;
		ret = fh.erase(baddr);
		if (ret == 0)
			ret = fh.program(baddr, fh.buffer);
		if (ret < 0) {
			fh.lock(baddr);	/* Best effort; report the first error */
			goto out;
		}
		if ((ret = fh.lock(baddr)) < 0) goto out;

		printk("fh: block 0x%08lx programmed\n", baddr);

		if (memcmp((char *)fh.vdata + baddr, fh.buffer, FH_BLOCK_SIZE)) {
			printk("fh: block 0x%08lx verify fails\n", baddr);
			ret = -EIO;
			goto out;
		}
		printk("fh: block 0x%08lx verified\n", baddr);
		*f_pos = baddr + FH_BLOCK_SIZE;
	}
	ret = count;

  out:
	up(&fh.sem);
	return ret;
}

static ssize_t fh_read(struct file *filp, char __user *buf, size_t count, loff_t *f_pos)
{
	unsigned char *fwhub = (unsigned char *)fh.vdata;
	unsigned long foffs = (unsigned long)*f_pos;
	ssize_t ret = 0;

	if (down_interruptible(&fh.sem)) {
		return -ERESTARTSYS;
	}
	if (foffs >= fh.size) {
		goto out;
	}
	if (count > (fh.size - foffs)) {
		count = fh.size - foffs;
	}
	if (copy_to_user(buf, &fwhub[foffs], count)) {
		ret = -EFAULT;
		goto out;
	}
	*f_pos += count;
	ret = count;

  out:
	up(&fh.sem);
	return ret;
}

static int __init fh_init(void)
{
	int ret = -ENXIO;

	if ((fh.vdata = ioremap(FH_DATA_PHYS, FH_DATA_SIZE)) == NULL) {
		printk("fh_init: ioremap fails\n");
		ret = -ENOMEM;
		goto fail;
	}
	if ((fh.vlock = ioremap(FH_LOCK_PHYS, FH_LOCK_SIZE)) == NULL) {
		printk("fh_init: ioremap fails\n");
		ret = -ENOMEM;
		goto fail;
	}
	if (sst4900_present()) {
		fh.lock		= fwhub_lock;
		fh.unlock	= fwhub_unlock;
		fh.erase	= sst4900_erase;
		fh.program	= sst4900_program;
	} else if (i82802_present()) {
		fh.lock		= fwhub_lock;
		fh.unlock	= fwhub_unlock;
		fh.erase	= i82802_erase;
		fh.program	= i82802_program;
	} else {
		printk("fh: no supported firmware hub was detected\n");
		ret = -ENXIO;
		goto fail;
	}
	sema_init(&fh.sem, 1);
	if ((ret = misc_register(&fh_dev)) < 0) {
		printk("fh_init: misc_register fails (%d)\n", ret);
		ret = -ENODEV;
		goto fail;
	}
	return 0;

  fail:
	if (fh.vdata != NULL) {
		iounmap(fh.vdata);
		fh.vdata = NULL;
	}
	if (fh.vlock != NULL) {
		iounmap(fh.vlock);
		fh.vlock = NULL;
	}
	return ret;
}

static void __exit fh_exit(void)
{
	if (fh.vdata != NULL) {
		iounmap(fh.vdata);
	}
	if (fh.vlock != NULL) {
		iounmap(fh.vlock);
	}
	misc_deregister(&fh_dev);
}

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OpenFrame firmware hub (EFI flash) access");
module_init(fh_init);
module_exit(fh_exit);

/*
 * end fh.c
 */
