/*
 *  linux/kernel/mktime.c
 *
 *  (C) 1991  Linus Torvalds
 */

#include <time.h>		// 时间头文件，定义了标准时间数据结构tm和一些处理时间函数原型

/*
 * This isn't the library routine, it is only used in the kernel.
 * as such, we don't care about years<1970 etc, but assume everything
 * is ok. Similarly, TZ etc is happily ignored. We just do everything
 * as easily as possible. Let's find something public for the library
 * routines (although I think minix times is public).
 */
/*
 * PS. I hate whoever though up the year 1970 - couldn't they have gotten
 * a leap-year instead? I also hate Gregorius, pope or no. I'm grumpy.
 */
#define MINUTE 60
#define HOUR (60*MINUTE)
#define DAY (24*HOUR)
#define YEAR (365*DAY)

/* interestingly, we assume leap-years */
static int month[12] = {
	0,
	DAY*(31),
	DAY*(31+29),
	DAY*(31+29+31),
	DAY*(31+29+31+30),
	DAY*(31+29+31+30+31),
	DAY*(31+29+31+30+31+30),
	DAY*(31+29+31+30+31+30+31),
	DAY*(31+29+31+30+31+30+31+31),
	DAY*(31+29+31+30+31+30+31+31+30),
	DAY*(31+29+31+30+31+30+31+31+30+31),
	DAY*(31+29+31+30+31+30+31+31+30+31+30)
};

// 该函数计算从 1970 年 1 月 1 日 0 时起到开机当日经过的秒数，作为开机时间。 
// 参数 tm 中各字段已经在 init/main.c 中被赋值，信息取自 CMOS。
long kernel_mktime(struct tm * tm)
{
	long res;
	int year;

// 首先计算1970年到现在经过的年数。因为是 2 位表示方式，所以会有 2000 年问题。我们可以
// 简单地在最前面添加一条语句来解决这个问题：if (tm->tm_year<70) tm->tm_year += 100;
// 由于 UNIX 计年份 y 是从 1970 年算起。到 1972 年就是一个闰年，因此过 3 年（71，72，73） 
// 就是第 1 个闰年，这样从 1970 年开始的闰年数计算方法就应该是为 1 + (y - 3)/4，即为 
// (y + 1)/4。res = 这些年经过的秒数时间 + 每个闰年时多 1 天的秒数时间 + 当年到当月时 
// 的秒数。另外，month[]数组中已经在 2 月份的天数中包含进了闰年时的天数，即 2 月份天数 
// 多算了 1 天。因此，若当年不是闰年并且当前月份大于 2 月份的话，我们就要减去这天。因 
// 为从 70 年开始算起，所以当年是闰年的判断方法是 (y + 2) 能被 4 除尽。若不能除尽（有余 
// 数）就不是闰年。
	year = tm->tm_year - 70;	// tm_year是相对于1900年的年份，减去70得到的是自1970年开始的年数
/* magic offsets (y+1) needed to get leapyears right.*/
	res = YEAR*year + DAY*((year+1)/4);
	res += month[tm->tm_mon];
/* and (y+2) here. If it wasn't a leap-year, we have to adjust */
	if (tm->tm_mon>1 && ((year+2)%4))
		res -= DAY;
	res += DAY*(tm->tm_mday-1);	// 再加上本月过去的天数的秒数时间
	res += HOUR*tm->tm_hour;	// 再加上当天过去的小时数的秒数时间
	res += MINUTE*tm->tm_min;	// 再加上1小时内过去的分钟数的秒数时间
	res += tm->tm_sec;			// 再加上1分钟内已过的秒数
	return res;					// 即等于从1970年来进过的秒数时间
}
