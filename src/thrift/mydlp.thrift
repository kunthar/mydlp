/**
 *     Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@medra.com.tr>
 * 
 ***************************************************************************
 *     This file is part of MyDLP.
 * 
 *     MyDLP is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 * 
 *     MyDLP is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 * 
 *     You should have received a copy of the GNU General Public License
 *     along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
 ***************************************************************************/

exception GeneralException {
	1: string why
}

service Mydlp {
	string getMagicMime(1 : binary Data) throws (1: GeneralException ge)
	bool isValidIban(1 : string IbanStr)
	binary htmlToText(1 : binary Data) throws (1: GeneralException ge)
	bool checkBinaryIntegrity(1 : string FilePath)
	bool checkArchiveIntegrity(1 : string FilePath)
}
