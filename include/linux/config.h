#ifndef _CONFIG_H
#define _CONFIG_H

/*
 * Defines for what uname() should return 
 * UTS在这里代表Unix Time-Sharing System，是Linux内核之中用于标识操作系统的一部分
 */
#define UTS_SYSNAME "Linux"
#define UTS_NODENAME "(none)"	/* set by sethostname() */
#define UTS_RELEASE "0"		/* patchlevel */
#define UTS_VERSION "0.12"
#define UTS_MACHINE "i386"	/* hardware type */

/*
 * The following are for system dependent settings
 * DEF在这里代表default
 */
/* Don't touch these, unless you really know what your doing. */
#define DEF_INITSEG	0x9000 /* 默认本程序代码段移动目的段位置 */
#define DEF_SYSSEG	0x1000 /* 默认系统模块长度。单位是节，每节为16字节 */
#define DEF_SETUPSEG	0x9020 /* 默认setup程序代码段位置 */
#define DEF_SYSSIZE	0x3000 /* 默认系统模板长度。单位是节，每节为16字节 */

/*
 * The root-device is no longer hard-coded. You can change the default
 * root-device by changing the line ROOT_DEV = XXX in boot/bootsect.s
 */

/*
 * The keyboard is now defined in kernel/chr_dev/keyboard.S
 */

/*
 * Normally, Linux can get the drive parameters from the BIOS at
 * startup, but if this for some unfathomable reason fails, you'd
 * be left stranded. For this case, you can define HD_TYPE, which
 * contains all necessary info on your harddisk.
 *
 * The HD_TYPE macro should look like this:
 *
 * #define HD_TYPE { head, sect, cyl, wpcom, lzone, ctl}
 *
 * In case of two harddisks, the info should be sepatated by
 * commas:
 *
 * #define HD_TYPE { h,s,c,wpcom,lz,ctl },{ h,s,c,wpcom,lz,ctl }
 */

/*
 This is an example, two drives, first is type 2, second is type 3:

#define HD_TYPE { 4,17,615,300,615,8 }, { 6,17,615,300,615,0 }

 NOTE: ctl is 0 for all drives with heads<=8, and ctl=8 for drives
 with more than 8 heads.

 If you want the BIOS to tell what kind of drive you have, just
 leave HD_TYPE undefined. This is the normal thing to do.
*/

#endif
