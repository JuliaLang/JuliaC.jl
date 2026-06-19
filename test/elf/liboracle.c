__asm__(".symver g1_0,g1@");
__asm__(".symver g1_1_1,g1@LIBORACLE_1.1");
__asm__(".symver g1_1_2,g1@LIBORACLE_1.2");
__asm__(".symver g1_2_0,g1@@LIBORACLE_2.0");

int g1_0(void) {return 100;}
int g1_1_1(void) {return 111;}
int g1_1_2(void) {return 112;}
int g1_2_0(void) {return 120;}

/* only defined in 1.2 */
int g2(void) {return 212;}

/* only defined in 2.0 */
int g3(void) {return 320;}
