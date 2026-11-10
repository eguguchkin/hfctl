{a[NR]=$1} END{ if (NR>0) { if (NR%2) printf "%.3f", a[(NR+1)/2]; else printf "%.3f", (a[NR/2]+a[NR/2+1])/2 } }
