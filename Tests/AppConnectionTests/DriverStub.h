#include "DriverConnection.h"

// Configures the IOKit boundary without requiring a physical YubiKey.
void YKTestSetResults(kern_return_t openResult, kern_return_t infoResult, int missingService);
